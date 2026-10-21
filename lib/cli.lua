-- Headless entry point: argument parsing, tool dispatch, selftest runner.
-- Returns an exit code; prints through injectable out/err sinks so tests can
-- call it in-process without a subprocess.

local json = require "json"
local registry = require "tools"
local check = require "check"

local M = {}

------------------------------------------------------------------- paths

local function repo_root()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local dir = src:match("^(.*)[/\\][^/\\]*$") or "."
  local parent = dir:match("^(.*)[/\\]lib$")
  if parent then return parent end
  if dir == "lib" then return "." end
  return dir
end

M.root = repo_root()

local function exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function deps()
  local d = {
    submodules = exists(M.root .. "/submodules/LuaJIT-ImGui/CMakeLists.txt"),
    lib = exists(M.root .. "/build/out/cimgui_glfw.dll")
      or exists(M.root .. "/build/out/libcimgui_glfw.so"),
  }
  if d.lib then
    local ok, kit = pcall(require, "imguikit")
    d.binding = ok and kit.available() or false
  end
  return d
end

------------------------------------------------------------------- helpers

local function sorted()
  local list = {}
  for i, e in ipairs(registry) do list[i] = e end
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.id < b.id
  end)
  return list
end

local function load_tool(id)
  local ok, mod = pcall(require, "tools." .. id:gsub("%.", "_"))
  if not ok then return nil, tostring(mod) end
  if type(mod) ~= "table" or type(mod.run) ~= "function" then
    return nil, "tool '" .. id .. "' has no run()"
  end
  return mod
end

local function read_input(path)
  if path == "-" then
    return io.read("*a") or ""
  end
  local f, ferr = io.open(path, "rb")
  if not f then return nil, ferr or ("cannot open " .. path) end
  local s = f:read("*a")
  f:close()
  return s or ""
end

local HELP = [[
tinytools — a tiny toolbox for LuaJIT developers

usage:
  luajit apps/toolbox.lua                       start the GUI
  luajit apps/toolbox.lua --list [--json]       list tools
  luajit apps/toolbox.lua --run <id> [input]    run one tool headlessly
  luajit apps/toolbox.lua --selftest            run every tool's selftest
  luajit apps/toolbox.lua --check               dependency probe + selftests
  luajit apps/toolbox.lua --smoke N             hidden window, N frames, exit 0
  luajit apps/toolbox.lua --help

run options:
  --text STR              inline input for the tool
  --in FILE               read input from FILE ("-" for stdin)
  --opt KEY=VALUE         tool option, repeatable (example: --opt mode=minify)
  --json                  machine-readable output

exit codes:
  0  success
  1  tool or selftest failure, unknown tool, bad arguments
  3  GUI requested but not available in this build
]]

local function usage_error(err, msg)
  err("tinytools: " .. msg .. "\n")
  err("try --help\n")
  return 1
end

------------------------------------------------------------------- commands

local function list_tools(out, as_json)
  local list = sorted()
  if as_json then
    local payload = {}
    for i, e in ipairs(list) do
      payload[i] = { id = e.id, group = e.group, name = e.name, keywords = e.keywords }
    end
    out(json.encode(payload) .. "\n")
    return 0
  end
  for _, e in ipairs(list) do
    out(string.format("%-14s %-11s %s\n", e.id, e.group, e.name))
  end
  return 0
end

local function run_selftests(out, with_deps)
  if with_deps then
    local d = deps()
    out(string.format("deps: submodules=%s build/out=%s binding=%s\n",
      d.submodules and "present" or "missing",
      d.lib and "present" or "missing",
      d.binding and "loadable" or "not loadable"))
  end

  local failures = 0
  for _, entry in ipairs(sorted()) do
    local mod, lerr = load_tool(entry.id)
    if not mod then
      failures = failures + 1
      out("FAIL " .. entry.id .. "\n       " .. lerr .. "\n")
    else
      local t = check.new(entry.id)
      local ok, crash = pcall(mod.selftest, t)
      if not ok then t:fail("crashed: " .. tostring(crash)) end
      if t.count == 0 then t:fail("no assertions") end
      if not t:ok() then failures = failures + 1 end
      out(t:report() .. "\n")
    end
  end

  out(string.format("%d tool(s), %d failing\n", #registry, failures))
  return failures == 0 and 0 or 1
end

local function run_tool(out, err, o)
  local entry
  for _, e in ipairs(sorted()) do
    if e.id == o.run then entry = e end
  end
  if not entry then
    return usage_error(err, "unknown tool '" .. tostring(o.run) .. "' (see --list)")
  end

  local mod, lerr = load_tool(o.run)
  if not mod then
    err("tinytools: " .. lerr .. "\n")
    return 1
  end

  local input = ""
  if o.text ~= nil then
    input = o.text
  elseif o.infile ~= nil then
    local s, rerr = read_input(o.infile)
    if not s then
      err("tinytools: " .. tostring(rerr) .. "\n")
      return 1
    end
    input = s
  end

  local ok, result, rerr = pcall(mod.run, input, o.opts)
  if not ok then
    err("tinytools: " .. tostring(result) .. "\n")
    return 1
  end
  if result == nil then
    err("tinytools: " .. tostring(rerr or "tool failed") .. "\n")
    return 1
  end

  if o.json then
    out(json.encode({
      id = o.run,
      text = result.text,
      data = result.json or {},
    }) .. "\n")
  else
    out((result.text or "") .. "\n")
  end
  return 0
end

------------------------------------------------------------------- parsing

local function parse(argv)
  local o = { opts = {} }
  local i = 1

  while i <= #argv do
    local a = argv[i]
    if a == "--list" then
      o.list = true
    elseif a == "--json" then
      o.json = true
    elseif a == "--selftest" then
      o.selftest = true
    elseif a == "--check" then
      o.check = true
    elseif a == "--smoke" then
      i = i + 1
      local frames = tonumber(argv[i])
      if not frames or frames < 1 then return nil, "--smoke needs a frame count >= 1" end
      o.smoke = math.floor(frames)
    elseif a == "--help" or a == "-h" then
      o.help = true
    elseif a == "--run" then
      i = i + 1
      o.run = argv[i]
      if not o.run then return nil, "--run needs a tool id" end
    elseif a == "--text" then
      i = i + 1
      if argv[i] == nil then return nil, "--text needs a value" end
      o.text = argv[i]
    elseif a == "--in" then
      i = i + 1
      if argv[i] == nil then return nil, "--in needs a file" end
      o.infile = argv[i]
    elseif a == "--opt" then
      i = i + 1
      local pair = argv[i]
      if not pair then return nil, "--opt needs KEY=VALUE" end
      local k, v = pair:match("^([^=]+)=(.*)$")
      if not k then return nil, "--opt needs KEY=VALUE, got '" .. pair .. "'" end
      o.opts[k] = v
    else
      return nil, "unknown argument '" .. tostring(a) .. "'"
    end
    i = i + 1
  end

  return o
end

-- The GUI is injected so tests never open a window: env.gui is either a
-- function(opts) -> code, frames, false to force "unavailable", or nil for real.
-- Returns the runner plus whether it was injected (injected runners are trusted
-- as-is; the real one is probed for the binding first).
local function pick_gui(env)
  if env and env.gui ~= nil then
    if env.gui == false then return nil, true end
    return env.gui, true
  end
  return function(opts)
    local ok, kit = pcall(require, "imguikit")
    if not ok then return nil, tostring(kit) end
    if not opts.draw then
      local drawn, shell = pcall(require, "shell")
      if not drawn then return nil, tostring(shell) end
      opts.draw = shell.draw
    end
    return kit.run(opts)
  end, false
end

local function gui_ready()
  local ok, kit = pcall(require, "imguikit")
  if not ok then return false, "imguikit: " .. tostring(kit) end
  return kit.available()
end

local function launch(out, err, gui, injected, opts)
  if not injected then
    local ready, why = gui_ready()
    if not ready then
      out("tinytools: " .. tostring(why) .. "\n")
      return nil
    end
  end

  local called, code, detail = pcall(gui, opts)
  if not called then
    err("tinytools: " .. tostring(code) .. "\n")
    return 1, nil
  end
  if code == nil then
    err("tinytools: " .. tostring(detail) .. "\n")
    return 1, nil
  end
  return 0, detail
end

local function gui_unavailable(out)
  out("tinytools: the GUI needs the ImGui binding (run `make submodules libs`).\n")
  out("headless commands work without it: --list, --run <id>, --selftest, --check\n")
  return 3
end

function M.main(argv, out, err, env)
  out = out or function(s) io.write(s) end
  err = err or function(s) io.stderr:write(s) end
  argv = argv or {}

  if #argv == 0 then
    local gui, injected = pick_gui(env)
    if not gui then return gui_unavailable(out) end
    local code = launch(out, err, gui, injected, { title = "tinytools" })
    if code == nil then return gui_unavailable(out) end
    return code
  end

  local o, perr = parse(argv)
  if not o then return usage_error(err, perr) end

  if o.help then
    out(HELP)
    return 0
  end
  if o.list then
    return list_tools(out, o.json)
  end
  if o.selftest or o.check then
    return run_selftests(out, o.check)
  end
  if o.smoke then
    local gui, injected = pick_gui(env)
    if not gui then return gui_unavailable(out) end
    local code, detail = launch(out, err, gui, injected, {
      title = "tinytools (smoke)",
      visible = false,
      frames = o.smoke,
      dont_sleep = true,
    })
    if code == nil then return gui_unavailable(out) end
    if code ~= 0 then return code end
    out(string.format("smoke: rendered %d frames\n", tonumber(detail) or 0))
    return 0
  end
  if o.run then
    return run_tool(out, err, o)
  end

  return usage_error(err, "nothing to do")
end

return M
