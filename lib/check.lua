-- Tiny assertion recorder shared by tool selftests and the test runner.
-- Usage:
--   local check = require "check"
--   local t = check.new("data.base64")
--   t:eq(1 + 1, 2, "addition")
--   t:ok()      --> boolean
--   t:count     --> number of assertions made

local M = {}
M.__index = M

local function show(v)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "table" then return "table" end
  return tostring(v)
end

function M.new(name)
  return setmetatable({
    name = name or "check",
    count = 0,
    failures = {},
  }, M)
end

function M:fail(msg)
  self.failures[#self.failures + 1] = msg
  return false
end

function M:truthy(v, what)
  self.count = self.count + 1
  if v then return true end
  return self:fail((what or "value") .. ": expected truthy, got " .. show(v))
end

function M:falsy(v, what)
  self.count = self.count + 1
  if not v then return true end
  return self:fail((what or "value") .. ": expected falsy, got " .. show(v))
end

function M:eq(got, want, what)
  self.count = self.count + 1
  if got == want then return true end
  return self:fail(string.format("%s: expected %s, got %s",
    what or "value", show(want), show(got)))
end

function M:neq(got, unwanted, what)
  self.count = self.count + 1
  if got ~= unwanted then return true end
  return self:fail(string.format("%s: expected not %s", what or "value", show(unwanted)))
end

function M:near(got, want, eps, what)
  self.count = self.count + 1
  eps = eps or 1e-9
  if type(got) == "number" and math.abs(got - want) <= eps then return true end
  return self:fail(string.format("%s: expected %s +/- %s, got %s",
    what or "value", show(want), show(eps), show(got)))
end

-- Asserts fun() raises; `pattern` is an optional Lua pattern for the message.
function M:raises(fun, pattern, what)
  self.count = self.count + 1
  local ok, err = pcall(fun)
  if ok then
    return self:fail((what or "call") .. ": expected an error, none raised")
  end
  if pattern and not tostring(err):find(pattern) then
    return self:fail(string.format("%s: error %q does not match %q",
      what or "call", tostring(err), pattern))
  end
  return true
end

function M:ok()
  return #self.failures == 0
end

function M:report()
  if self:ok() then
    return string.format("ok   %s (%d checks)", self.name, self.count)
  end
  return string.format("FAIL %s\n       %s", self.name,
    table.concat(self.failures, "\n       "))
end

return M
