-- The window content: sidebar (search, groups, favorites) and one tool panel.
-- The panel is generic on purpose: every tool exposes run(), so the shell can
-- drive them all with an input box, an options line and an output area. Tools
-- that need a custom layout (JWT, diff) get a draw() later and fall back to this.

local ffi = require "ffi"
local registry = require "tools"

local M = {}

local S = {
  search = ffi.new("char[128]"),
  fav_only = ffi.new("bool[1]"),
  selected = registry[1] and registry[1].id or nil,
  favorites = {},
  tools = {},
}

M.state = S

local function tool_state(id)
  local st = S.tools[id]
  if not st then
    st = {
      input = ffi.new("char[65536]"),
      opts = ffi.new("char[256]"),
      output = "",
      error = nil,
    }
    S.tools[id] = st
  end
  return st
end

local function entry_for(id)
  for _, e in ipairs(registry) do
    if e.id == id then return e end
  end
end

local function matches(entry, query)
  if query == "" then return true end
  local q = query:lower()
  if entry.id:lower():find(q, 1, true) or entry.name:lower():find(q, 1, true) then
    return true
  end
  for _, keyword in ipairs(entry.keywords) do
    if keyword:find(q, 1, true) then return true end
  end
  return false
end

local function parse_opts(text)
  local opts = {}
  for pair in text:gmatch("[^;]+") do
    local key, value = pair:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key then opts[key] = value end
  end
  return opts
end

local function run_current(entry, st)
  local ok, mod = pcall(require, "tools." .. entry.id:gsub("%.", "_"))
  if not ok then
    st.output, st.error = "", "cannot load tool: " .. tostring(mod)
    return
  end

  local called, result, err = pcall(mod.run, ffi.string(st.input), parse_opts(ffi.string(st.opts)))
  if not called then
    st.output, st.error = "", tostring(result)
    return
  end
  if result == nil then
    st.output, st.error = "", tostring(err or "tool failed")
    return
  end
  st.error = nil
  st.output = result.text or ""
end

local function draw_sidebar(ig, lib)
  ig.BeginChild("sidebar", ig.ImVec2(230, 0), lib.ImGuiChildFlags_Borders)

  ig.InputTextWithHint("##search", "search tools...", S.search, ffi.sizeof(S.search))
  ig.Checkbox("favorites only", S.fav_only)

  local query = ffi.string(S.search)
  local groups, order = {}, {}
  for _, entry in ipairs(registry) do
    local keep = matches(entry, query)
    if keep and S.fav_only[0] and not S.favorites[entry.id] then keep = false end
    if keep then
      if not groups[entry.group] then
        groups[entry.group] = {}
        order[#order + 1] = entry.group
      end
      local list = groups[entry.group]
      list[#list + 1] = entry
    end
  end

  if #order == 0 then
    ig.Text("no tools match")
  end

  for _, group in ipairs(order) do
    if ig.CollapsingHeader(group .. "##group") then
      for _, entry in ipairs(groups[group]) do
        local star = S.favorites[entry.id] and "* " or "  "
        local label = star .. entry.name .. "##" .. entry.id
        if ig.Selectable(label, S.selected == entry.id) then
          S.selected = entry.id
        end
      end
    end
  end

  ig.EndChild()
end

local function draw_tool(ig, lib, ui)
  local entry = entry_for(S.selected)
  if not entry then
    ig.Text("select a tool")
    return
  end

  local st = tool_state(entry.id)

  ig.Text(entry.name)
  ig.SameLine()
  if ig.Button(S.favorites[entry.id] and "* unfavorite" or "* favorite") then
    S.favorites[entry.id] = not S.favorites[entry.id] or nil
  end
  ig.SameLine()
  ig.Text("(" .. entry.id .. ")")

  ig.InputText("options##opts", st.opts, ffi.sizeof(st.opts))
  ig.Text("options are k=v pairs separated by ';', e.g. mode=minify; indent=4")

  local avail = ig.GetContentRegionAvail()
  local input_height = math.max(80, avail.y * 0.32)
  ig.InputTextMultiline("##input", st.input, ffi.sizeof(st.input), ig.ImVec2(-1, input_height))

  if ig.Button("Run") then
    run_current(entry, st)
  end
  ig.SameLine()
  if ig.Button("Clear") then
    st.input[0] = 0
    st.output, st.error = "", nil
  end
  ig.SameLine()
  if ig.Button("Copy output") and #st.output > 0 then
    ui.window:setClipboardString(st.output)
  end

  ig.Separator()

  if st.error then
    ig.Text("error: " .. st.error)
  elseif #st.output > 0 then
    ig.TextWrapped(st.output)
  else
    ig.Text("press Run")
  end
end

local function imgui_version(ig)
  local ok, version = pcall(function() return ig.GetVersion() end)
  if ok and type(version) == "string" then return version end
  return "cimgui"
end

function M.draw(ig, ui)
  local lib = ig.lib

  draw_sidebar(ig, lib)
  ig.SameLine()
  ig.BeginChild("content", ig.ImVec2(0, -ig.GetFrameHeightWithSpacing()), lib.ImGuiChildFlags_Borders)
  draw_tool(ig, lib, ui)
  ig.EndChild()

  ig.Separator()
  ig.Text(string.format("%d tools | LuaJIT %s | imgui %s | FPS %.0f",
    #registry, jit.version, imgui_version(ig), ui.fps))
end

M.run_current = run_current
M.parse_opts = parse_opts
M.matches = matches

return M
