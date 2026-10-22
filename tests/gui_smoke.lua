-- Optional integration checks using the real binding and a hidden GL window.
local here = (arg[0]):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../lib/?.lua;" .. here .. "/../lib/?/init.lua;" .. package.path
local ffi = require "ffi"
local bit = require "bit"
local kit = require "imguikit"
local shell = require "shell"
local store = require "store"
local t = require("check").new("GUI interactions")
local original_path = store.path
store.path = here .. "/tmp_gui_favorites.json"
os.remove(store.path)
local clipboard, copied, click, shortcut
local output_drawn, wrap_flags, texts
local steps = {
  function() shell.state.selected = "data.json" end,
  function() clipboard = '{"text":"100% %s %n"}'; click = "Paste" end,
  function() click = "Run (Ctrl+Enter)" end,
  function()
    t:truthy(output_drawn, "real read-only output widget renders")
    t:truthy(bit.band(wrap_flags, 16777216) ~= 0, "output wrapping enabled")
    click = "Copy output"
  end,
  function()
    t:eq(copied, shell.state.tools["data.json"].output, "copy gets the complete result")
    t:truthy(texts["Copied!"], "copy confirmation displayed")
    click = "* favorite"
  end,
  function()
    t:eq(store.load()["data.json"], true, "favorite saved to disk")
    shell.state.favorites, shell.state.settings_loaded = {}, false
  end,
  function()
    t:eq(shell.state.favorites["data.json"], true, "favorite restored on reload")
    click = "Clear"
  end,
  function()
    local st = shell.state.tools["data.json"]
    t:eq(ffi.string(st.input), "", "Clear resets input")
    t:eq(st.has_result, false, "Clear resets result status")
    shell.state.selected = "data.base64"
  end,
  function() click = "Run (Ctrl+Enter)" end,
  function()
    t:truthy(texts["Success: empty result"], "empty successful result is explicit")
    clipboard, click = "hello", "Paste"
  end,
  function() shortcut = true end,
  function()
    t:eq(shell.state.tools["data.base64"].output, "aGVsbG8=", "Ctrl+Enter runs selected tool")
    local st = shell.state.tools["data.base64"]
    st.wrap[0] = false
  end,
  function()
    t:eq(bit.band(wrap_flags, 16777216), 0, "wrap can be disabled")
    clipboard, click = string.rep("x", 65536), "Paste"
  end,
  function()
    local st = shell.state.tools["data.base64"]
    t:eq(ffi.string(st.input), "hello", "oversized clipboard preserves input")
    t:truthy(st.notice:find("65535", 1, true), "input limit explained")
    shell.state.selected = "num.base"
  end,
  function() clipboard, click = "255", "Paste" end,
  function() click = "Run (Ctrl+Enter)" end,
  function()
    t:eq(shell.state.tools["num.base"].output, "ff", "number controls run")
    shell.state.selected = "hash.crc32"
  end,
  function() clipboard, click = "123456789", "Paste" end,
  function() click = "Run (Ctrl+Enter)" end,
  function()
    t:eq(shell.state.tools["hash.crc32"].output, "cbf43926", "checksum controls run")
    shell.state.selected = "gen.uuid"
  end,
  function() click = "Run (Ctrl+Enter)" end,
  function()
    t:eq(#shell.state.tools["gen.uuid"].output, 36, "UUID controls run")
  end,
}
local code, err = kit.run {
  visible = false, frames = #steps, dont_sleep = true,
  draw = function(ig, ui)
    click, shortcut = nil, false
    steps[ui.frame + 1]()
    output_drawn, wrap_flags, texts = false, 0, {}
    local proxy = setmetatable({}, { __index = ig })
    proxy.Button = function(label, ...)
      local pressed = ig.Button(label, ...)
      return pressed or label == click
    end
    proxy.GetIO = function() return { KeyCtrl = shortcut } end
    proxy.IsWindowFocused = function() return true end
    proxy.IsKeyPressed_Bool = function() return shortcut end
    proxy.InputTextMultiline = function(label, buf, len, size, flags)
      if label == "##output" then
        output_drawn, wrap_flags = true, flags
        t:truthy(bit.band(flags, ig.lib.ImGuiInputTextFlags_ReadOnly) ~= 0,
          "output is read-only")
      end
      return ig.InputTextMultiline(label, buf, len, size, flags)
    end
    proxy.Text = function(fmt, ...)
      texts[string.format(fmt, ...)] = true
      return ig.Text(fmt, ...)
    end
    local fake_ui = setmetatable({ window = {
      getClipboardString = function() return clipboard end,
      setClipboardString = function(_, value) copied = value end,
    } }, { __index = ui })
    shell.draw(proxy, fake_ui)
  end,
}
os.remove(store.path)
os.remove(store.path .. ".tmp")
store.path = original_path
t:eq(code, 0, "GUI lifecycle succeeds: " .. tostring(err))
print(t:report())
os.exit(t:ok() and 0 or 1)
