-- Bundler script: Combines all application Lua files into a single standalone Lua script.
-- Submodules (gl.lua, glfw.lua, imgui/) and DLLs are NOT bundled; they are referenced
-- dynamically from build/out at runtime via package.path and PATH.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local root = here:match("^(.*)[/\\]scripts$") or here
if root == "scripts" or root == "" then root = "." end

local out_file = (arg and arg[1]) or (root .. "/tinytools_bundle.lua")

local modules = {
  { name = "check",            path = root .. "/lib/check.lua" },
  { name = "timer",            path = root .. "/lib/timer.lua" },
  { name = "json",             path = root .. "/lib/json.lua" },
  { name = "detect",           path = root .. "/lib/detect.lua" },
  { name = "store",            path = root .. "/lib/store.lua" },
  { name = "tool_options",     path = root .. "/lib/tool_options.lua" },
  { name = "tools",            path = root .. "/lib/tools/init.lua" },
  { name = "tools.data_base64",path = root .. "/lib/tools/data_base64.lua" },
  { name = "tools.data_json",  path = root .. "/lib/tools/data_json.lua" },
  { name = "tools.num_base",   path = root .. "/lib/tools/num_base.lua" },
  { name = "tools.hash_crc32", path = root .. "/lib/tools/hash_crc32.lua" },
  { name = "tools.gen_uuid",   path = root .. "/lib/tools/gen_uuid.lua" },
  { name = "imguikit",         path = root .. "/lib/imguikit.lua" },
  { name = "shell",            path = root .. "/lib/shell.lua" },
  { name = "cli",              path = root .. "/lib/cli.lua" },
}

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then error("Cannot read " .. path .. ": " .. tostring(err)) end
  local content = f:read("*a")
  f:close()
  return content
end

local pieces = {}

table.insert(pieces, [[
-- =============================================================================
-- tinytools_bundle.lua
-- Single-file bundled edition of tinytools.
-- All internal app modules are preloaded into package.preload.
-- External dependencies (GLFW, OpenGL, ImGui) are referenced dynamically
-- from build/out (or the directory configured in TINYTOOLS_OUT).
-- =============================================================================

]])

for _, m in ipairs(modules) do
  local content = read_file(m.path)
  table.insert(pieces, string.format([[
-- -----------------------------------------------------------------------------
-- Module: %s (from %s)
-- -----------------------------------------------------------------------------
package.preload["%s"] = function(...)
%s
end

]], m.name, m.path, m.name, content))
end

table.insert(pieces, [[
-- =============================================================================
-- Application Entry Point
-- =============================================================================
os.exit(require("cli").main(arg or {}))
]])

local out_h, err = io.open(out_file, "wb")
if not out_h then
  io.stderr:write("Failed to open " .. out_file .. " for writing: " .. tostring(err) .. "\n")
  os.exit(1)
end

out_h:write(table.concat(pieces))
out_h:close()

print("Successfully created standalone bundle: " .. out_file)
