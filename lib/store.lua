-- Favorites live beside the application, including in portable bundles.
local ffi = require "ffi"
local json = require "json"
local M = {}
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local dir = source:match("^(.*)[/\\][^/\\]*$") or "."
M.path = dir .. "/../state/settings.json"

local wide
if ffi.os == "Windows" then
  ffi.cdef [[
    int MultiByteToWideChar(unsigned int, uint32_t, const char*, int, uint16_t*, int);
    int CreateDirectoryW(const uint16_t*, void*);
    int MoveFileExW(const uint16_t*, const uint16_t*, uint32_t);
    uint32_t GetLastError(void);
  ]]
  wide = function(s)
    local n = ffi.C.MultiByteToWideChar(65001, 8, s, -1, nil, 0)
    assert(n > 0, "invalid UTF-8 settings path")
    local out = ffi.new("uint16_t[?]", n)
    assert(ffi.C.MultiByteToWideChar(65001, 8, s, -1, out, n) > 0)
    return out
  end
else
  ffi.cdef [[int mkdir(const char*, unsigned int);]]
end

function M.load(path)
  local f, err, code = io.open(path or M.path, "rb")
  if not f then
    if code == 2 then return {} end
    return {}, "Cannot load favorites: " .. tostring(err)
  end
  local data = f:read("*a")
  f:close()
  local ok, settings = pcall(json.decode, data or "")
  if not ok or type(settings) ~= "table" or type(settings.favorites) ~= "table" then
    return {}, "Cannot load favorites: invalid settings file"
  end
  local favorites = {}
  for id, enabled in pairs(settings.favorites) do
    if type(id) == "string" and enabled == true then favorites[id] = true end
  end
  return favorites
end

function M.save(favorites, path)
  path = path or M.path
  local ok, err = pcall(function()
    local parent = assert(path:match("^(.*)[/\\][^/\\]*$"), "settings directory missing")
    if ffi.os == "Windows" then
      if ffi.C.CreateDirectoryW(wide(parent), nil) == 0 then
        assert(ffi.C.GetLastError() == 183, "cannot create settings directory")
      end
    else
      if ffi.C.mkdir(parent, 448) ~= 0 then
        assert(ffi.errno() == 17, "cannot create settings directory")
      end
    end
    local data = json.encode({ favorites = favorites })
    local tmp = path .. ".tmp"
    local f = assert(io.open(tmp, "wb"))
    local written, write_err = f:write(data)
    local closed, close_err = f:close()
    assert(written, write_err)
    assert(closed, close_err)
    if ffi.os == "Windows" then
      assert(ffi.C.MoveFileExW(wide(tmp), wide(path), 9) ~= 0, "cannot replace settings file")
    else
      assert(os.rename(tmp, path))
    end
  end)
  if not ok then return nil, "Cannot save favorites: " .. tostring(err) end
  return true
end

return M
