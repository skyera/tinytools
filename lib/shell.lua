-- The window content: sidebar (search, groups, favorites) and one tool panel.
-- Shared input/output panes drive the headless run() contract. Tool-specific
-- option controls are metadata in tool_options, without eager tool loading.

local ffi = require "ffi"
local bit = require "bit"
local registry = require "tools"
local options = require "tool_options"
local store = require "store"
local timer = require "timer"

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
      controls = options.new(id),
      wrap = ffi.new("bool[1]", true),
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
  st.has_result, st.output_buf, st.dirty = false, nil, false
  st.notice, st.copied_until = nil, nil
  local ok, mod = pcall(require, "tools." .. entry.id:gsub("%.", "_"))
  if not ok then
    st.output, st.error = "", "cannot load tool: " .. tostring(mod)
    return
  end

  local opts = st.controls and options.values(entry.id, st.controls)
    or parse_opts(ffi.string(st.opts))
  local called, result, err = pcall(mod.run, ffi.string(st.input), opts)
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
  st.has_result = true
end

local function paste_input(st, text)
  if not text then st.notice = "Clipboard is empty"; return false end
  local limit = ffi.sizeof(st.input) - 1
  if #text > limit then
    st.notice = string.format("Clipboard has %d bytes; input limit is %d. Input was kept.", #text, limit)
    return false
  end
  if text:find("\0", 1, true) then
    st.notice = "Clipboard contains NUL bytes; input supports text only. Input was kept."
    return false
  end
  ffi.copy(st.input, text, #text)
  st.input[#text] = 0
  st.notice, st.dirty = nil, true
  return true
end

local function output_buffer(st)
  if not st.output_buf then
    -- C text widgets stop at NUL; keep the raw result for reporting/copying.
    local preview = st.output:gsub("%z", "\\0")
    st.output_buf = ffi.new("char[?]", #preview + 1, preview)
  end
  return st.output_buf
end

local function draw_sidebar(ig, lib, height, max_width)
  ig.SetNextWindowSizeConstraints(ig.ImVec2(math.min(140, max_width), 0),
    ig.ImVec2(max_width, math.huge))
  local visible = ig.BeginChild("sidebar", ig.ImVec2(math.min(230, max_width), height),
    bit.bor(lib.ImGuiChildFlags_Borders, lib.ImGuiChildFlags_ResizeX))
  if not visible then
    ig.EndChild()
    return
  end

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
    if ig.CollapsingHeader(group .. "##group", lib.ImGuiTreeNodeFlags_DefaultOpen) then
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
  st.controls = st.controls or options.new(entry.id)
  st.wrap = st.wrap or ffi.new("bool[1]", true)
  ig.PushID_Str(entry.id)

  ig.Text("%s", entry.name)
  ig.SameLine()
  if ig.Button(S.favorites[entry.id] and "* unfavorite" or "* favorite") then
    S.favorites[entry.id] = not S.favorites[entry.id] or nil
    local saved, err = store.save(S.favorites)
    S.settings_error = saved and nil or err
  end
  ig.SameLine()
  ig.Text("(%s)", entry.id)

  if options.draw(ig, entry.id, st.controls) then st.dirty = true end

  local shortcut = ig.GetIO().KeyCtrl and ig.IsWindowFocused(lib.ImGuiFocusedFlags_RootAndChildWindows)
    and ig.IsKeyPressed_Bool(lib.ImGuiKey_Enter, false)
  if ig.Button("Run (Ctrl+Enter)") or shortcut then
    run_current(entry, st)
  end
  ig.SameLine()
  if ig.Button("Clear") then
    st.input[0] = 0
    st.output, st.error = "", nil
    st.output_buf, st.has_result, st.dirty = nil, false, false
    st.notice, st.copied_until = nil, nil
  end
  ig.SameLine()
  if ig.Button("Paste") then
    local ok, text = pcall(function() return ui.window:getClipboardString() end)
    if ok then paste_input(st, text) else st.notice = "Cannot read clipboard: " .. tostring(text) end
  end
  ig.SameLine()
  ig.BeginDisabled(not st.has_result or #st.output == 0)
  if ig.Button("Copy output") and st.has_result and #st.output > 0 then
    if st.output:find("\0", 1, true) then
      st.notice = "Output contains NUL bytes; the clipboard supports text only."
    else
      local ok, err = pcall(function() ui.window:setClipboardString(st.output) end)
      if ok then
        st.copied_until, st.notice = timer.now() + 2, nil
      else st.notice = "Cannot copy output: " .. tostring(err) end
    end
  end
  ig.EndDisabled()
  if st.copied_until and timer.now() < st.copied_until then ig.Text("Copied!") end
  if st.notice then ig.TextWrapped("%s", st.notice) end

  local bytes, limit = #ffi.string(st.input), ffi.sizeof(st.input) - 1
  ig.Text("%s", string.format("Input: %d / %d bytes", bytes, limit))
  if bytes == limit then ig.TextWrapped("Input is at the limit; pasted text may have been truncated.") end
  local avail = ig.GetContentRegionAvail()
  local input_height = math.max(60, (avail.y - ig.GetFrameHeightWithSpacing() * 3) * 0.45)
  if ig.InputTextMultiline("##input", st.input, ffi.sizeof(st.input), ig.ImVec2(-1, input_height)) then
    st.dirty = true
  end

  if st.dirty then ig.Text("Input or options changed; run again to update output") end
  ig.Text("%s", string.format("Output: %d bytes", #st.output))
  ig.SameLine()
  ig.Checkbox("Wrap", st.wrap)
  if st.error then
    ig.TextWrapped("error: %s", st.error)
  elseif st.has_result then
    if #st.output == 0 then ig.Text("Success: empty result") end
    if st.output:find("\0", 1, true) then ig.Text("NUL bytes are displayed as \\0") end
    if #st.output > 0 then
      local flags = lib.ImGuiInputTextFlags_ReadOnly
      if st.wrap[0] then flags = bit.bor(flags, lib.ImGuiInputTextFlags_WordWrap) end
      local buf = output_buffer(st)
      ig.InputTextMultiline("##output", buf, ffi.sizeof(buf),
        ig.ImVec2(-1, math.max(60, ig.GetContentRegionAvail().y)), flags)
    end
  else
    ig.Text("Press Run to see the result")
  end
  ig.PopID()
end

local function imgui_version(ig)
  local ok, version = pcall(function() return ig.GetVersion() end)
  if ok and type(version) == "string" then return version end
  return "cimgui"
end

function M.draw(ig, ui)
  if not S.settings_loaded then
    S.favorites, S.settings_error = store.load()
    S.settings_loaded = true
  end
  local lib = ig.lib
  local viewport = ig.GetMainViewport()
  ig.SetNextWindowPos(viewport.WorkPos)
  ig.SetNextWindowSize(viewport.WorkSize)
  local flags = bit.bor(lib.ImGuiWindowFlags_NoDecoration,
    lib.ImGuiWindowFlags_NoMove, lib.ImGuiWindowFlags_NoSavedSettings)
  if not ig.Begin("tinytools##main", nil, flags) then
    ig.End()
    return
  end

  local avail = ig.GetContentRegionAvail()
  local spacing = ig.GetStyle().ItemSpacing
  -- Both panels share a height, leaving room for the separator and status text.
  local height = math.max(1, avail.y - ig.GetFrameHeightWithSpacing() - spacing.y)
  local sidebar_max = math.max(1, avail.x - 200 - spacing.x)
  draw_sidebar(ig, lib, height, sidebar_max)
  ig.SameLine()
  if ig.BeginChild("content", ig.ImVec2(0, height), lib.ImGuiChildFlags_Borders) then
    if S.settings_error then ig.TextWrapped("%s", S.settings_error) end
    draw_tool(ig, lib, ui)
  end
  ig.EndChild()

  ig.Separator()
  ig.Text("%s", string.format("%d tools | LuaJIT %s | imgui %s | FPS %.0f",
    #registry, jit.version, imgui_version(ig), ui.fps))
  ig.End()
end

M.run_current = run_current
M.parse_opts = parse_opts
M.matches = matches
M.paste_input = paste_input

return M
