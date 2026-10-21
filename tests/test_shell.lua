-- The shell is mostly ImGui calls, but its logic (filtering, option parsing,
-- running the selected tool) is plain Lua and testable without a window.

local ffi = require "ffi"
local shell = require "shell"
local registry = require "tools"

local M = {}

local function entry_for(id)
  for _, entry in ipairs(registry) do
    if entry.id == id then return entry end
  end
end

local function state_with(input, opts)
  local st = {
    input = ffi.new("char[4096]"),
    opts = ffi.new("char[256]"),
    output = "",
    error = nil,
  }
  ffi.copy(st.input, input, #input + 1)
  ffi.copy(st.opts, opts or "", #(opts or "") + 1)
  return st
end

function M.run(t)
  -- options parsing
  local opts = shell.parse_opts("mode=minify; indent=4;sort=0")
  t:eq(opts.mode, "minify", "option value")
  t:eq(opts.indent, "4", "numeric option stays a string")
  t:eq(opts.sort, "0", "second option")
  t:eq(shell.parse_opts("")["mode"], nil, "empty options")
  t:eq(shell.parse_opts("junk")["junk"], nil, "option without = is ignored")

  -- filtering
  local base64 = entry_for("data.base64")
  t:truthy(shell.matches(base64, ""), "empty query matches")
  t:truthy(shell.matches(base64, "b64"), "keyword match")
  t:truthy(shell.matches(base64, "BASE"), "name match is case-insensitive")
  t:truthy(shell.matches(base64, "data."), "id match")
  t:falsy(shell.matches(base64, "crc32"), "non-match")

  -- running the selected tool, exactly as the Run button does
  local st = state_with("hello", "")
  shell.run_current(base64, st)
  t:eq(st.output, "aGVsbG8=", "run button output")
  t:eq(st.error, nil, "run button has no error")

  st = state_with("aGVsbG8=", "decode=true")
  shell.run_current(base64, st)
  t:eq(st.output, "hello", "run with options")
  t:eq(st.error, nil, "decoding has no error")

  -- tool errors land in st.error, not in output
  local json_tool = entry_for("data.json")
  st = state_with("{", "")
  shell.run_current(json_tool, st)
  t:eq(st.output, "", "invalid input clears output")
  t:truthy(st.error and st.error:find("invalid JSON") ~= nil, "invalid input sets error")

  -- state.error clears on the next successful run
  st = state_with('{"a":1}', "mode=minify")
  shell.run_current(json_tool, st)
  t:eq(st.error, nil, "error clears after success")
  t:eq(st.output, '{"a":1}', "minify via options line")
end

return M
