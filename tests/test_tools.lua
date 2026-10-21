-- Every registered tool must load and pass its own selftest.

local registry = require "tools"
local check = require "check"

local M = {}

function M.run(t)
  for _, entry in ipairs(registry) do
    local ok, mod = pcall(require, "tools." .. entry.id:gsub("%.", "_"))
    if not ok then
      t:fail("cannot load " .. entry.id .. ": " .. tostring(mod))
    else
      local c = check.new(entry.id)
      local ran, crash = pcall(mod.selftest, c)
      if not ran then c:fail("crashed: " .. tostring(crash)) end

      t:truthy(c.count > 0, entry.id .. ": selftest makes assertions")
      if not c:ok() then
        for _, failure in ipairs(c.failures) do
          t:fail(entry.id .. ": " .. failure)
        end
      end
      t:truthy(c:ok(), entry.id .. ": selftest passes")
    end
  end
end

return M
