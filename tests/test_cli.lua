-- CLI dispatch in-process: exit codes, output shape, error paths.
-- Sinks are injected so nothing here needs a subprocess.

local cli = require "cli"
local json = require "json"

local M = {}

local function capture()
  local buf = {}
  local sink = function(s) buf[#buf + 1] = s end
  return sink, function() return table.concat(buf) end
end

local function noop() end

function M.run(t)
  -- --list, text form
  local out, text = capture()
  t:eq(cli.main({ "--list" }, out, noop), 0, "--list exit 0")
  t:truthy(text():find("data.json") ~= nil, "--list mentions data.json")
  t:truthy(text():find("Base64") ~= nil, "--list mentions Base64")

  -- --list, JSON form
  out, text = capture()
  t:eq(cli.main({ "--list", "--json" }, out, noop), 0, "--list --json exit 0")
  local ok, listed = pcall(json.decode, text())
  t:truthy(ok, "--list --json output parses")
  t:truthy(ok and #listed >= 5, "--list --json has every tool")
  t:truthy(ok and listed[1].id ~= nil, "--list --json entries have ids")

  -- --run with inline text
  out, text = capture()
  t:eq(cli.main({ "--run", "data.base64", "--text", "hello" }, out, noop), 0, "--run base64 exit 0")
  t:eq(text(), "aGVsbG8=\n", "--run base64 output")

  -- --run with tool options
  out, text = capture()
  t:eq(cli.main({ "--run", "data.json", "--text", '{"b":1,"a":2}', "--opt", "mode=minify" }, out, noop),
    0, "--opt mode=minify exit 0")
  t:eq(text(), '{"a":2,"b":1}\n', "--opt mode=minify output")

  -- --json envelope is machine-readable and keeps the tool's data
  out, text = capture()
  t:eq(cli.main({ "--run", "hash.crc32", "--text", "123456789", "--json" }, out, noop), 0, "--json exit 0")
  local envelope_ok, envelope = pcall(json.decode, text())
  t:truthy(envelope_ok, "--json envelope parses")
  t:eq(envelope.id, "hash.crc32", "--json envelope id")
  t:eq(envelope.text, "cbf43926", "--json envelope text")
  t:eq(envelope.data.crc32, "cbf43926", "--json envelope data.crc32")

  -- --run with a file
  local path = "tests/tmp_in.txt"
  local f = assert(io.open(path, "wb"))
  f:write("foobar")
  f:close()
  out, text = capture()
  t:eq(cli.main({ "--run", "data.base64", "--in", path }, out, noop), 0, "--in file exit 0")
  t:eq(text(), "Zm9vYmFy\n", "--in file output")
  os.remove(path)

  -- unknown tool
  local errbuf = {}
  local function esink(s) errbuf[#errbuf + 1] = s end
  out, text = capture()
  t:eq(cli.main({ "--run", "nope.nope" }, out, esink), 1, "unknown tool exits 1")
  t:truthy(table.concat(errbuf):find("unknown tool") ~= nil, "unknown tool message")

  -- tool rejects its input
  errbuf = {}
  out, text = capture()
  t:eq(cli.main({ "--run", "data.json", "--text", "{" }, out, esink), 1, "invalid input exits 1")
  t:truthy(table.concat(errbuf):find("invalid JSON") ~= nil, "invalid input message")

  -- bad arguments
  errbuf = {}
  out, text = capture()
  t:eq(cli.main({ "--wat" }, out, esink), 1, "unknown flag exits 1")
  t:eq(cli.main({ "--opt", "novalue", "--list" }, out, esink), 1, "--opt without = exits 1")
  t:eq(cli.main({ "--run" }, out, esink), 1, "--run without id exits 1")

  -- help, selftest, check
  out, text = capture()
  t:eq(cli.main({ "--help" }, out, noop), 0, "--help exit 0")
  t:truthy(text():find("usage:") ~= nil, "--help prints usage")

  out, text = capture()
  t:eq(cli.main({ "--selftest" }, out, noop), 0, "--selftest exit 0")
  t:truthy(text():find("ok   data.json") ~= nil, "--selftest reports data.json")
  t:truthy(text():find("0 failing") ~= nil, "--selftest reports no failures")

  out, text = capture()
  t:eq(cli.main({ "--check" }, out, noop), 0, "--check exit 0")
  t:truthy(text():find("deps:") ~= nil, "--check reports dependencies")

  -- no arguments: GUI path
  out, text = capture()
  t:eq(cli.main({}, out, noop, { gui = false }), 3, "no args without the binding exits 3")
  t:truthy(text():find("make submodules libs") ~= nil, "no-args message names the fix")

  local launched
  local stub = function(opts)
    launched = opts
    return 0, 1
  end
  out, text = capture()
  t:eq(cli.main({}, out, noop, { gui = stub }), 0, "no args launches the GUI")
  t:eq(launched.title, "tinytools", "GUI gets a title")
  t:falsy(launched.visible == false, "normal launch is visible")

  -- --smoke: hidden window, exact frame count, injected runner
  launched = nil
  out, text = capture()
  t:eq(cli.main({ "--smoke", "300" }, out, noop, { gui = stub }), 0, "--smoke exit 0")
  t:eq(launched.frames, 300, "--smoke passes the frame count")
  t:eq(launched.visible, false, "--smoke runs hidden")
  t:truthy(text():find("rendered 1 frames") ~= nil, "--smoke reports frames rendered")

  out, text = capture()
  t:eq(cli.main({ "--smoke", "300" }, out, noop, { gui = false }), 3, "--smoke without the binding exits 3")

  local failing = function() return nil, "glfw.init() failed" end
  errbuf = {}
  out, text = capture()
  t:eq(cli.main({ "--smoke", "10" }, out, esink, { gui = failing }), 1, "--smoke failure exits 1")
  t:truthy(table.concat(errbuf):find("glfw.init") ~= nil, "--smoke failure message")

  errbuf = {}
  out, text = capture()
  t:eq(cli.main({ "--smoke" }, out, esink, { gui = false }), 1, "--smoke without count exits 1")
end

return M
