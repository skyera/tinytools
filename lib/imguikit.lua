-- The only code that knows about build/out and how to open a window.
--
-- Loads the FFI binding (cimgui_glfw + glfw3) from a repo-local prefix, runs a
-- frame loop the caller can configure, and always shuts down in reverse order.
-- Docking and multi-viewport are deliberately off: this is a single-window app.

local ffi = require "ffi"
local timer = require "timer"

local M = {}

------------------------------------------------------------------- paths

local function module_dir()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local dir = src:match("^(.*)[/\\][^/\\]*$") or "."
  return dir
end

local function repo_root()
  local dir = module_dir()
  local parent = dir:match("^(.*)[/\\]lib$")
  if parent then return parent end
  if dir == "lib" then return "." end
  if dir == "." then return "." end
  return dir
end

M.root = repo_root()

local function default_out()
  return M.root .. "/build/out"
end

-- LoadLibrary on Windows does not consult package.cpath, so the directory has
-- to be on PATH before any binding does ffi.load("glfw3").
-- On Linux, ffi.load with an unqualified name does not consult package.cpath,
-- so preload the build/out shared objects globally into the process.
local function add_dll_dir(dir)
  if ffi.os ~= "Windows" then
    pcall(ffi.load, dir .. "/libglfw.so.3", true)
    pcall(ffi.load, dir .. "/libcimgui_glfw.so", true)
    return
  end

  local ok = pcall(ffi.cdef, [[
    uint32_t GetEnvironmentVariableA(const char *name, char *buffer, uint32_t size);
    int32_t SetEnvironmentVariableA(const char *name, const char *value);
  ]])
  if not ok then return end

  local buf = ffi.new("char[32768]")
  local n = ffi.C.GetEnvironmentVariableA("PATH", buf, 32768)
  if n == 0 or n >= 32768 then return end

  local current = ffi.string(buf, n)
  if (";" .. current .. ";"):find(";" .. dir .. ";", 1, true) then return end
  ffi.C.SetEnvironmentVariableA("PATH", dir .. ";" .. current)
end

-- Prepends the build prefix to package.path and (on Windows) to PATH.
-- Idempotent; safe to call before every launch.
function M.require_env(out)
  out = out or os.getenv("TINYTOOLS_OUT") or default_out()
  out = out:gsub("\\", "/")

  if M.out == out then return out end

  package.path = out .. "/lua/?.lua;" .. out .. "/lua/?/init.lua;" .. package.path
  package.cpath = out .. "/?.dll;" .. out .. "/?.so;" .. out .. "/lib?.so;" .. package.cpath
  add_dll_dir(out)

  M.out = out
  return out
end

-- True when the binding can be loaded without opening a window.
function M.available()
  local ok_env, env_err = pcall(function() return M.require_env() end)
  if not ok_env then return false, tostring(env_err) end

  local out = M.out
  local needed = ffi.os == "Windows"
    and { "cimgui_glfw.dll", "glfw3.dll" }
    or { "libcimgui_glfw.so", "libglfw.so.3" }
  for _, name in ipairs(needed) do
    local probe = io.open(out .. "/" .. name, "rb")
    if not probe then
      return false, out .. "/" .. name .. " missing (run `make libs`)"
    end
    probe:close()
  end

  local loaded, err = pcall(require, "imgui.glfw")
  if not loaded then return false, tostring(err) end
  return true
end

------------------------------------------------------------------- run

-- opts:
--   title, w, h, visible (default true), frames (stop after N), fps (default 60),
--   vsync (default 1), draw(ig, ui)
-- Returns 0, or nil plus a message when the window could not start.
function M.run(opts)
  opts = opts or {}
  local draw = opts.draw
  if type(draw) ~= "function" then
    return nil, "imguikit.run needs a draw function"
  end
  local target_fps = opts.fps or 60
  if type(target_fps) ~= "number" or target_fps ~= target_fps
    or target_fps <= 0 or target_fps >= math.huge then
    return nil, "fps must be a finite positive number"
  end

  local ready, why = M.available()
  if not ready then
    return nil, "ImGui binding unavailable: " .. tostring(why)
  end

  local glfw, imgui, window, ig_impl
  local glfw_started, platform_started, renderer_started = false, false, false
  local ini_path -- Keep the Lua string alive while ImGui holds its pointer.
  local frame = 0
  local ok, failure = xpcall(function()
    glfw = require "glfw"
    local gl = require "gl"
    gl.set_loader(glfw)
    imgui = require "imgui.glfw"

    local w = opts.w or 1180
    local h = opts.h or 720
    local visible = opts.visible ~= false

    glfw.setErrorCallback(function(code, description)
      io.stderr:write(string.format("GLFW error %s: %s\n", tostring(code),
        ffi.string(description or "")))
    end)

    -- The binding's init() returns nothing and raises on failure.
    glfw_started = true
    glfw.init()

    if not visible then
      glfw.hint(glfw.glfwc.GLFW_VISIBLE, 0)
    end

    window = glfw.Window(w, h, opts.title or "tinytools")
    window:makeContextCurrent()
    local vsync = opts.vsync or 1
    glfw.swapInterval(vsync)

    local gl_functions, gl_constants = gl.libraries()
    ig_impl = imgui.Imgui_Impl_glfw_opengl3()

    -- DPI and style, applied once.
    local scale = 1
    local scaled = pcall(function()
      scale = tonumber(imgui.lib.ImGui_ImplGlfw_GetContentScaleForMonitor(glfw.getPrimaryMonitor()))
    end)
    if not scaled or not scale or scale <= 0 then scale = 1 end
    pcall(function()
      imgui.GetStyle():ScaleAllSizes(scale)
      imgui.GetStyle().FontScaleDpi = scale
    end)
    pcall(function()
      local io = imgui.GetIO()
      io.ConfigFlags = imgui.lib.ImGuiConfigFlags_NavEnableKeyboard + io.ConfigFlags
      io.ConfigDpiScaleFonts = true
      local state_dir = os.getenv("TINYTOOLS_STATE_DIR")
      if state_dir then
        ini_path = state_dir .. "/imgui.ini"
        io.IniFilename = ini_path
      end
    end)

    -- Track each backend separately: a partially initialized context must not
    -- call Shutdown on a backend whose Init failed.
    platform_started = imgui.lib.ImGui_ImplGlfw_InitForOpenGL(window, true)
    assert(platform_started, "GLFW ImGui backend initialization failed")
    renderer_started = imgui.lib.ImGui_ImplOpenGL3_Init("#version 130")
    assert(renderer_started, "OpenGL ImGui backend initialization failed")

    local fps = 0
    local last = timer.now()

    while not window:shouldClose() do
      local started = timer.now()
      glfw.pollEvents()

      if (tonumber(window:getAttrib(glfw.glfwc.GLFW_ICONIFIED)) or 0) ~= 0 then
        pcall(function() imgui.lib.ImGui_ImplGlfw_Sleep(10) end)
      else
        window:makeContextCurrent()
        gl_functions.glClear(gl_constants.GL_COLOR_BUFFER_BIT)

        ig_impl:NewFrame()

        local ui = {
          frame = frame,
          dt = timer.now() - last,
          fps = fps,
          window = window,
          kit = M,
        }
        last = timer.now()

        draw(imgui, ui)

        ig_impl:Render()
        window:swapBuffers()

        if vsync == 0 and not opts.dont_sleep then
          local remaining = (1 / target_fps - (timer.now() - started)) * 1000
          if remaining >= 1 then imgui.lib.ImGui_ImplGlfw_Sleep(math.floor(remaining)) end
        end

        fps = ui.dt > 0 and (1 / ui.dt) or 0
        frame = frame + 1
      end

      if opts.frames and frame >= opts.frames then break end
    end

  end, debug.traceback)

  -- Attempt every cleanup even when another cleanup fails. Preserve the
  -- original error so callers can diagnose initialization or frame failures.
  local function cleanup(fn)
    local cleaned, err = pcall(fn)
    if not cleaned and ok then ok, failure = false, tostring(err) end
  end
  if window then cleanup(function() window:makeContextCurrent() end) end
  if renderer_started then cleanup(function() imgui.lib.ImGui_ImplOpenGL3_Shutdown() end) end
  if platform_started then cleanup(function() imgui.lib.ImGui_ImplGlfw_Shutdown() end) end
  if ig_impl then cleanup(function() imgui.DestroyContext(ig_impl.ctx) end) end
  if window then cleanup(function() window:destroy() end) end
  if glfw_started then cleanup(function() glfw.terminate() end) end

  if not ok then return nil, tostring(failure) end
  return 0, frame
end

return M
