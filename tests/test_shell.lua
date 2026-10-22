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

  -- GUI controls feed the same options contract as the CLI.
  local options = require "tool_options"
  st = state_with("-_8", "")
  st.controls = options.new(base64.id)
  st.controls.decode[0] = true
  shell.run_current(base64, st)
  t:eq(st.output, string.char(251, 255), "decode checkbox reaches the tool")
  st = state_with("", "")
  st.controls = options.new(base64.id)
  shell.run_current(base64, st)
  t:eq(st.output, "", "empty input has an empty result")
  t:eq(st.has_result, true, "empty result is successful")
  st = state_with("{", "")
  shell.run_current(json_tool, st)
  t:eq(st.has_result, false, "tool error is distinct from an empty success")

  local numeric = options.new("num.base")
  numeric.time[0] = 1
  t:eq(options.values("num.base", numeric).time, "epoch", "epoch dropdown option")
  numeric.time[0] = 2
  t:eq(options.values("num.base", numeric).time, "iso", "ISO dropdown option")
  local checksum = options.new("hash.crc32")
  checksum.algo[0] = 1
  t:eq(options.values("hash.crc32", checksum).algo, "adler32", "checksum dropdown option")
  local uuid = options.new("gen.uuid")
  uuid.count[0] = 2
  t:eq(options.values("gen.uuid", uuid).count, 2, "UUID count control")

  st = state_with("original", "")
  local full = string.rep("x", ffi.sizeof(st.input) - 1)
  t:truthy(shell.paste_input(st, full), "paste accepts input at the limit")
  t:eq(ffi.string(st.input), full, "paste at limit is terminated correctly")
  t:falsy(shell.paste_input(st, full .. "x"), "oversized paste rejected")
  t:eq(ffi.string(st.input), full, "oversized paste preserves input")
  t:truthy(st.notice, "oversized paste explains the limit")
  t:falsy(shell.paste_input(st, "a\0b"), "NUL paste rejected")
  t:eq(ffi.string(st.input), full, "NUL paste preserves input")
  t:truthy(shell.paste_input(st, "short"), "shorter paste succeeds")
  t:eq(ffi.string(st.input), "short", "shorter paste removes old suffix")

  -- Exercise the rendering boundary without passing unsafe formats to C.
  -- The fake text functions interpret formats just as the binding does.
  local rendered = {}
  local function text(fmt, ...)
    rendered[#rendered + 1] = string.format(fmt, ...)
  end
  local function noop() end
  local viewport = { WorkPos = { x = 0, y = 0 }, WorkSize = { x = 1180, y = 720 } }
  local window_open, window_visible = false, true
  local window_pos, window_size, window_name, window_flags
  local begins, ends = 0, 0
  local ig = {
    lib = { ImGuiChildFlags_Borders = 1, ImGuiWindowFlags_NoDecoration = 43,
      ImGuiWindowFlags_NoMove = 4, ImGuiWindowFlags_NoSavedSettings = 256,
      ImGuiChildFlags_ResizeX = 4, ImGuiTreeNodeFlags_DefaultOpen = 32,
      ImGuiInputTextFlags_ReadOnly = 512, ImGuiInputTextFlags_WordWrap = 16777216,
      ImGuiFocusedFlags_RootAndChildWindows = 3, ImGuiKey_Enter = 525 },
    PushID_Str = noop, PopID = noop, BeginDisabled = noop, EndDisabled = noop,
    SetNextItemWidth = noop, Combo_Str = noop, InputInt = noop,
    GetIO = function() return { KeyCtrl = false } end,
    GetMainViewport = function() return viewport end,
    SetNextWindowPos = function(pos) window_pos = pos end,
    SetNextWindowSize = function(size) window_size = size end,
    SetNextWindowSizeConstraints = noop,
    Begin = function(name, _, flags)
      assert(not window_open, "main window must not nest")
      window_open = true
      begins = begins + 1
      window_name, window_flags = name, flags
      return window_visible
    end,
    End = function()
      assert(window_open, "End requires a matching Begin")
      window_open = false
      ends = ends + 1
    end,
    ImVec2 = function(x, y) return { x = x, y = y } end,
    BeginChild = function()
      assert(window_open, "panels require the main window")
      return true
    end,
    EndChild = noop, SameLine = noop,
    InputTextWithHint = noop, Checkbox = noop, CollapsingHeader = noop,
    InputText = noop,
    InputTextMultiline = function(label, buf)
      if label == "##output" then rendered[#rendered + 1] = ffi.string(buf) end
    end,
    Button = noop,
    Separator = noop, Text = text, TextWrapped = text,
    GetContentRegionAvail = function() return { x = 600, y = 400 } end,
    GetStyle = function() return { ItemSpacing = { x = 8, y = 4 } } end,
    GetFrameHeightWithSpacing = function() return 20 end,
    GetVersion = function() return "test" end,
  }
  local saved_selected = shell.state.selected
  local saved_st = shell.state.tools[json_tool.id]
  shell.state.selected = json_tool.id
  st = state_with('{"text":"%s %n %d 100%"}', "mode=minify")
  shell.state.tools[json_tool.id] = st
  local drawn, draw_err = pcall(function()
    shell.run_current(json_tool, st)
    shell.draw(ig, { fps = 60 })
    t:eq(rendered[#rendered - 1], st.output, "output percent signs render literally")
    t:eq(window_name, "tinytools##main", "shell creates its own main window")
    t:eq(window_flags, 303, "main window is fixed and ignores saved geometry")
    t:eq(window_pos, viewport.WorkPos, "main window follows viewport position")
    t:eq(window_size, viewport.WorkSize, "main window fills viewport")
    viewport.WorkPos = { x = 10, y = 20 }
    viewport.WorkSize = { x = 800, y = 600 }
    st.error = "invalid option '%s %n %d 100%'"
    shell.draw(ig, { fps = 60 })
    t:eq(window_pos, viewport.WorkPos, "main window follows moved viewport")
    t:eq(window_size, viewport.WorkSize, "main window follows resized viewport")
    t:eq(rendered[#rendered - 1], "error: " .. st.error,
      "error percent signs render literally")
    window_visible = false
    local text_count = #rendered
    shell.draw(ig, { fps = 60 })
    t:eq(#rendered, text_count, "hidden main window skips content")
    t:eq(begins, 3, "each frame begins the main window")
    t:eq(ends, begins, "each Begin has an End, including hidden frames")
  end)
  shell.state.selected = saved_selected
  shell.state.tools[json_tool.id] = saved_st
  t:truthy(drawn, "percent-containing text renders safely: " .. tostring(draw_err))
end

return M
