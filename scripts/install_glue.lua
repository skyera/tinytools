-- Post-build step for `make libs`.
-- 1. copies the pure-Lua glue modules the CMake installs do not provide
--    (glfw.lua, gl.lua),
-- 2. copies the MinGW runtime DLLs the binding links against, so build/out works
--    without the toolchain being on PATH,
-- 3. verifies the artifacts exist and exits non-zero if one is missing.

local ffi = require "ffi"

local out = arg and arg[1] or "build/out"
local is_windows = ffi.os == "Windows"

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function write(path, data)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

local function copy(from, to, label)
  local data = read(from)
  if not data then
    return false, label .. ": source missing (" .. from .. ")"
  end
  local ok, err = write(to, data)
  if not ok then return false, label .. ": " .. tostring(err) end
  print("glue: " .. label .. " -> " .. to)
  return true
end

local problems = {}

for _, item in ipairs({
  { from = "submodules/LuaJIT-GLFW/glfw.lua", to = out .. "/lua/glfw.lua", label = "glfw.lua" },
  { from = "submodules/LuaJIT-GL/gl.lua", to = out .. "/lua/gl.lua", label = "gl.lua" },
}) do
  local ok, err = copy(item.from, item.to, item.label)
  if not ok then problems[#problems + 1] = err end
end

-- MinGW runtime DLLs are not in build/out by default; find them on PATH once.
local runtime = is_windows and { "libwinpthread-1.dll" } or {}
local search_sep = is_windows and ";" or ":"

for _, name in ipairs(runtime) do
  local target = out .. "/" .. name
  if exists(target) then
    print("runtime: " .. name .. " already present")
  else
    local found
    for dir in (os.getenv("PATH") or ""):gmatch("[^" .. search_sep .. "]+") do
      local candidate = (dir:gsub("[/\\]+$", "")) .. "/" .. name
      if exists(candidate) then
        found = candidate
        break
      end
    end
    if found then
      local ok, err = copy(found, target, name)
      if not ok then problems[#problems + 1] = err end
    else
      print("runtime: " .. name .. " NOT FOUND on PATH (the app may still load it at run time)")
    end
  end
end

-- The binding's base.lua binds some symbols eagerly (M.X = lib.X). Symbols that
-- this CMake configuration does not compile (cimCTE, FreeType) abort the load,
-- so disable exactly those lines: the rest of the binding stays untouched and
-- anything we actually call is still resolved through the real DLL.
local function add_to_path(dir)
  if not is_windows then return end
  local ok = pcall(ffi.cdef, [[
    uint32_t GetEnvironmentVariableA(const char *name, char *buffer, uint32_t size);
    int32_t SetEnvironmentVariableA(const char *name, const char *value);
  ]])
  if not ok then return end
  local buf = ffi.new("char[32768]")
  local n = ffi.C.GetEnvironmentVariableA("PATH", buf, 32768)
  if n == 0 or n >= 32768 then return end
  ffi.C.SetEnvironmentVariableA("PATH", dir .. ";" .. ffi.string(buf, n))
end

-- Asks the dynamic loader whether a symbol exists, without needing an ffi.cdef
-- for every name in the binding.
local function symbol_lookup(dll)
  if is_windows then
    add_to_path(dll:match("^(.*)[/\\][^/\\]*$") or ".")
    local ok = pcall(ffi.cdef, [[
      void *LoadLibraryA(const char *lpLibFileName);
      void *GetProcAddress(void *hModule, const char *lpProcName);
    ]])
    if not ok then return nil, "cannot declare loader functions" end
    local handle = ffi.C.LoadLibraryA(dll)
    if handle == nil then return nil, "LoadLibrary failed for " .. dll end
    return function(name) return ffi.C.GetProcAddress(handle, name) ~= nil end
  end

  local ok = pcall(ffi.cdef, [[
    void *dlopen(const char *filename, int flags);
    void *dlsym(void *handle, const char *symbol);
    char *dlerror(void);
  ]])
  if not ok then return nil, "cannot declare dl functions" end
  local dir = dll:match("^(.*)[/\\][^/\\]*$") or "."
  for _, name in ipairs({ "/libglfw.so.3", "/libglfw.so" }) do
    if exists(dir .. name) then
      ffi.C.dlopen(dir .. name, 258) -- RTLD_NOW | RTLD_GLOBAL
      break
    end
  end
  local handle = ffi.C.dlopen(dll, 2) -- RTLD_NOW
  if handle == nil then
    local err = ffi.C.dlerror()
    local msg = err ~= nil and ffi.string(err) or "unknown error"
    return nil, "dlopen failed for " .. dll .. ": " .. msg
  end
  return function(name) return ffi.C.dlsym(handle, name) ~= nil end
end

local function prune_binding(dir)
  local dll = dir .. (is_windows and "/cimgui_glfw.dll" or "/libcimgui_glfw.so")
  local path = dir .. "/lua/imgui/base.lua"
  if not exists(path) then return false, "prune: " .. path .. " missing" end

  local exported, lookup_err = symbol_lookup(dll)
  if not exported then return false, "prune: " .. tostring(lookup_err) end

  local text = read(path)
  if not text then return false, "prune: cannot read " .. path end

  local kept, dropped = 0, 0
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local symbol = line:match("^M%.[A-Za-z0-9_]+%s*=%s*lib%.([A-Za-z0-9_]+)%s*$")
    if symbol then
      if exported(symbol) then
        kept = kept + 1
      else
        line = "-- [tinytools] not exported by this build: " .. line
        dropped = dropped + 1
      end
    end
    lines[#lines + 1] = line
  end

  local ok, err = write(path, table.concat(lines, "\n"))
  if not ok then return false, "prune: " .. tostring(err) end
  print(string.format("prune: base.lua eager bindings %d kept, %d disabled", kept, dropped))
  return true
end

-- GLFW installs its DLL into bin/; the loader wants build/out flat.
if is_windows then
  local bin_dll = out .. "/bin/glfw3.dll"
  if not exists(out .. "/glfw3.dll") and exists(bin_dll) then
    local ok, err = copy(bin_dll, out .. "/glfw3.dll", "glfw3.dll (from bin/)")
    if not ok then problems[#problems + 1] = err end
  end
else
  -- On Linux/Unix, GLFW installs into lib/ or lib64/; the loader wants build/out flat.
  for _, libdir in ipairs({ out .. "/lib", out .. "/lib64" }) do
    for _, name in ipairs({ "libglfw.so.3", "libglfw.so" }) do
      local src = libdir .. "/" .. name
      local dst = out .. "/" .. name
      if not exists(dst) and exists(src) then
        local ok, err = copy(src, dst, name .. " (from " .. libdir .. "/)")
        if not ok then problems[#problems + 1] = err end
      end
    end
  end
end

do
  local ok, err = prune_binding(out)
  if not ok then problems[#problems + 1] = err end
end

local required = {
  out .. "/lua/glfw.lua",
  out .. "/lua/gl.lua",
  out .. "/lua/imgui/base.lua",
  out .. (is_windows and "/cimgui_glfw.dll" or "/libcimgui_glfw.so"),
  out .. (is_windows and "/glfw3.dll" or "/libglfw.so.3"),
}

for _, path in ipairs(required) do
  if not exists(path) then
    problems[#problems + 1] = "missing artifact: " .. path
  end
end

if #problems > 0 then
  for _, problem in ipairs(problems) do
    io.stderr:write("install_glue: " .. problem .. "\n")
  end
  os.exit(1)
end

print("install_glue: ok (" .. out .. ")")
