-- Test runner: luajit tests/run.lua
-- Loads every suite, runs it with the shared check recorder, prints one line per
-- suite, exits 0 only if all passed.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."

package.path = here .. "/../lib/?.lua;"
  .. here .. "/../lib/?/init.lua;"
  .. here .. "/?.lua;"
  .. package.path

local check = require "check"

local suites = {
  "test_registry",
  "test_tools",
  "test_detect",
  "test_shell",
  "test_cli",
}

local failures = 0
local checks = 0

for _, name in ipairs(suites) do
  local t = check.new(name)
  local ok, mod = pcall(require, name)

  if not ok then
    t:fail("failed to load: " .. tostring(mod))
  else
    local ran, crash = pcall(mod.run, t)
    if not ran then t:fail("crashed: " .. tostring(crash)) end
    if t.count == 0 and t:ok() then t:fail("no assertions") end
  end

  checks = checks + t.count
  if not t:ok() then failures = failures + 1 end
  print(t:report())
end

print(string.format("%d suite(s), %d checks, %d failing", #suites, checks, failures))
os.exit(failures == 0 and 0 or 1)
