-- Packaging step for `make dist`.
--
-- Assembles dist/tinytools/: the LuaJIT runtime, the app's own Lua sources, the
-- binding DLLs and glue from build/out, and a launcher that works from any cwd
-- (double-click -> GUI, arguments -> the CLI). No LuaJIT, CMake or toolchain is
-- needed on the target machine afterwards.
--
-- Layout is deliberately the repo's own: apps/ and lib/ stay siblings of
-- build/out, because imguikit and apps/toolbox.lua locate everything relative
-- to their source files.

local ffi = require "ffi"
local is_windows = ffi.os == "Windows"

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local root = here:match("^(.*)[/\\]scripts$") or here
if root == "scripts" then root = "." end

local stage = arg and arg[1] or (root .. "/dist/tinytools")

local problems = {}

local function note(msg) print("dist: " .. msg) end

local function fail(msg) problems[#problems + 1] = msg end

-- Never leave a half-written bundle behind: report and stop before staging.
local function abort()
  for _, msg in ipairs(problems) do io.stderr:write("dist: " .. msg .. "\n") end
  io.stderr:write("dist: nothing packaged\n")
  os.exit(1)
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write(path, data)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

local function dirname(path)
  return path:match("^(.*)[/\\][^/\\]*$")
end

local function makedirs(path)
  path = path:gsub("\\", "/")
  local built = path:sub(1, 1) == "/" and "/" or ""
  for part in path:gmatch("[^/]+") do
    built = built .. part
    if not exists(built .. "/.") then
      local cmd = is_windows
        and ('mkdir "' .. built:gsub("/", "\\") .. '" 2>nul')
        or ('mkdir -p "' .. built .. '" 2>/dev/null')
      os.execute(cmd)
    end
    built = built .. "/"
  end
end

-- `dir /b /s` prints absolute paths, so relative names have to be derived
-- against an absolute prefix, never against the argument as written.
local function absolute(path)
  path = path:gsub("\\", "/")
  if path:sub(1, 1) == "/" or path:match("^%a:") then return path end
  local pipe = io.popen(is_windows and "cd" or "pwd")
  local base = pipe and pipe:read("*l") or "."
  if pipe then pipe:close() end
  base = base:gsub("\\", "/"):gsub("\r$", ""):gsub("/+$", "")
  path = path:gsub("^%./", "")
  return base .. "/" .. path
end

-- Absolute listing; both branches return one path per line.
local function list_files(dir)
  local list = {}
  -- /a-d keeps directories out of the listing; find already filters them.
  local cmd = is_windows
    and ('dir /b /s /a-d "' .. dir:gsub("/", "\\") .. '" 2>nul')
    or ('find "' .. dir .. '" -type f 2>/dev/null')
  local pipe = io.popen(cmd)
  if not pipe then return list end
  for line in pipe:lines() do
    line = line:gsub("\r$", ""):gsub("\\", "/")
    if line ~= "" then list[#list + 1] = line end
  end
  pipe:close()
  return list
end

local function copy(from, to)
  local data = read(from)
  if not data then
    fail("missing " .. from)
    return false
  end
  makedirs(dirname(to))
  local ok, err = write(to, data)
  if not ok then
    fail("cannot write " .. to .. ": " .. tostring(err))
    return false
  end
  return true
end

-- Copies every file under from_dir into to_dir, preserving the subtree.
local function copy_tree(from_dir, to_dir)
  local prefix = absolute(from_dir)
  local copied = 0
  for _, path in ipairs(list_files(from_dir)) do
    local rel = path:sub(#prefix + 2)
    if rel ~= "" and copy(path, to_dir .. "/" .. rel) then copied = copied + 1 end
  end
  return copied
end

------------------------------------------------------------------- checks

local needed = is_windows
  and { "cimgui_glfw.dll", "glfw3.dll" }
  or { "libcimgui_glfw.so", "libglfw.so.3" }

for _, name in ipairs(needed) do
  if not exists(root .. "/build/out/" .. name) then
    fail("build/out/" .. name .. " missing (run `make libs` first)")
  end
end

if #problems > 0 then abort() end

-- The runtime: an explicit LUAJIT_EXE wins, otherwise ask the shell.
local function find_runtime()
  local explicit = os.getenv("LUAJIT_EXE")
  if explicit and exists(explicit) then return explicit end

  local cmd = is_windows and "where luajit 2>nul" or "command -v luajit 2>/dev/null"
  local pipe = io.popen(cmd)
  if pipe then
    for line in pipe:lines() do
      line = line:gsub("\r$", "")
      if exists(line) then
        pipe:close()
        return line
      end
    end
    pipe:close()
  end
end

local runtime = find_runtime()
if not runtime then
  fail("cannot find luajit.exe/luajit (set LUAJIT_EXE=/path/to/luajit)")
  abort()
end

local runtime_dir = dirname(runtime) or "."
local runtime_dll = runtime_dir .. (is_windows and "/lua51.dll" or "/libluajit-5.1.so.2")
if exists(runtime_dll) then
  note("runtime: " .. runtime .. " + " .. runtime_dll:match("[^/\\]+$"))
elseif is_windows then
  fail("lua51.dll must sit next to luajit.exe (" .. runtime_dll .. ")")
  abort()
else
  note("runtime: " .. runtime .. " (no " .. runtime_dll .. "; assuming a system LuaJIT)")
end

------------------------------------------------------------------- stage

makedirs(stage)

copy(runtime, stage .. "/" .. (is_windows and "luajit.exe" or "luajit"))
if exists(runtime_dll) then
  copy(runtime_dll, stage .. "/" .. runtime_dll:match("[^/\\]+$"))
end

copy(root .. "/apps/toolbox.lua", stage .. "/apps/toolbox.lua")

local lib_files = copy_tree(root .. "/lib", stage .. "/lib")
if lib_files == 0 then fail("copied no files from lib/") end

-- Only the loadable artifacts matter; leave headers and import libs behind.
for _, name in ipairs(needed) do
  copy(root .. "/build/out/" .. name, stage .. "/build/out/" .. name)
end
for _, name in ipairs({ "libwinpthread-1.dll" }) do
  if exists(root .. "/build/out/" .. name) then
    copy(root .. "/build/out/" .. name, stage .. "/build/out/" .. name)
  end
end
local glue_files = copy_tree(root .. "/build/out/lua", stage .. "/build/out/lua")
if glue_files == 0 then fail("copied no binding glue from build/out/lua") end

-- The binding is built RelWithDebInfo, so the unstripped DLL is ~70 MiB of
-- debug info. Stripping the *copy* keeps the build tree debuggable; a missing
-- strip is not fatal, the bundle is just larger.
if is_windows and os.getenv("TINYTOOLS_NO_STRIP") == nil then
  for _, name in ipairs(needed) do
    local target = stage .. "/build/out/" .. name
    os.execute('strip --strip-unneeded "' .. target:gsub("/", "\\") .. '" 2>nul')
  end
end

local launcher = [[
@echo off
rem tinytools portable launcher: no arguments opens the GUI, arguments go to the CLI.
setlocal
cd /d "%~dp0"
"%~dp0luajit.exe" "%~dp0apps\toolbox.lua" %*
exit /b %ERRORLEVEL%
]]
write(stage .. "/tinytools.bat", launcher:gsub("\n", "\r\n"))

local readme = string.format([[
tinytools — portable build

  tinytools.bat                 start the GUI
  tinytools.bat --list          list tools
  tinytools.bat --run data.base64 --text hello
  tinytools.bat --check         dependency probe + every selftest

Everything runs from this folder: LuaJIT, the tool sources, the ImGui binding
and its DLLs are all inside. Nothing is installed. Favorites are saved to
state/settings.json inside this folder; the folder must be writable to save.

Rebuild with `make dist` in the source checkout.
]])
write(stage .. "/README.txt", readme:gsub("\n", "\r\n"))

------------------------------------------------------------------- report

local total = 0
for _, path in ipairs(list_files(stage)) do
  local data = read(path)
  total = total + (#(data or ""))
end

note(string.format("%s (%d files, %.1f KiB)", stage,
  #list_files(stage), total / 1024))

if #problems > 0 then
  for _, msg in ipairs(problems) do io.stderr:write("dist: " .. msg .. "\n") end
  os.exit(1)
end

print("dist: run it with " .. stage .. "/tinytools.bat")
