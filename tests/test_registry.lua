-- Registry integrity: metadata and module files must agree.

local registry = require "tools"

local M = {}

local function module_name(id)
  return "tools." .. id:gsub("%.", "_")
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

function M.run(t)
  t:truthy(#registry >= 5, "registry has at least five tools")

  local seen = {}
  for _, entry in ipairs(registry) do
    local id = tostring(entry.id)
    t:truthy(not seen[id], "id is unique: " .. id)
    seen[id] = true

    t:truthy(id:match("^[a-z][a-z0-9_]*%.[a-z][a-z0-9_]*$") ~= nil, "id shape: " .. id)
    t:truthy(type(entry.group) == "string" and #entry.group > 0, "group for " .. id)
    t:truthy(type(entry.name) == "string" and #entry.name > 0, "name for " .. id)
    t:truthy(type(entry.keywords) == "table" and #entry.keywords > 0, "keywords for " .. id)
    t:truthy(type(entry.order) == "number", "order for " .. id)

    local path = "lib/tools/" .. id:gsub("%.", "_") .. ".lua"
    t:truthy(file_exists(path), "module file exists: " .. path)

    local ok, mod = pcall(require, module_name(id))
    t:truthy(ok, "module loads: " .. id .. (ok and "" or " (" .. tostring(mod) .. ")"))
    if ok then
      t:truthy(type(mod.run) == "function", "run() for " .. id)
      t:truthy(type(mod.selftest) == "function", "selftest() for " .. id)
      if mod.id ~= nil then
        t:eq(mod.id, id, "module id matches registry for " .. id)
      end
    end
  end
end

return M
