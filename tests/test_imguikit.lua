local kit = require "imguikit"
local M = {}

function M.run(t)
  local names = { "glfw", "gl", "imgui.glfw", "timer" }
  local saved = {}
  for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  local available = kit.available
  kit.available = function() return true end
  local ok, err = pcall(function()
    local function exercise(fail_at, opts, tick)
      local calls, sleeps, clock = {}, {}, 0
      local function step(name)
        calls[#calls + 1] = name
        if fail_at == name then error("injected " .. name) end
      end
      local window = {
        makeContextCurrent = function() step("context current") end,
        shouldClose = function() return false end,
        getAttrib = function() return 0 end,
        swapBuffers = function() step("swap") end,
        destroy = function() step("window destroy") end,
      }
      package.loaded.glfw = {
        glfwc = {}, setErrorCallback = function() end,
        init = function() step("glfw init") end,
        terminate = function() step("terminate") end,
        hint = function() end, swapInterval = function() end,
        Window = function() step("window create"); return window end,
        getPrimaryMonitor = function() return nil end,
        pollEvents = function() step("events") end,
      }
      package.loaded.gl = {
        set_loader = function() end,
        libraries = function()
          return { glClear = function() step("clear") end }, { GL_COLOR_BUFFER_BIT = 0 }
        end,
      }
      package.loaded["imgui.glfw"] = {
        lib = {
          ImGui_ImplGlfw_InitForOpenGL = function()
            step("platform init"); return fail_at ~= "platform false"
          end,
          ImGui_ImplOpenGL3_Init = function()
            step("renderer init"); return fail_at ~= "renderer false"
          end,
          ImGui_ImplOpenGL3_Shutdown = function() step("renderer shutdown") end,
          ImGui_ImplGlfw_Shutdown = function() step("platform shutdown") end,
          ImGui_ImplGlfw_Sleep = function(ms) sleeps[#sleeps + 1] = ms end,
        },
        Imgui_Impl_glfw_opengl3 = function()
          step("context create")
          return {
            ctx = {}, NewFrame = function() step("new frame") end,
            Render = function() step("render") end,
          }
        end,
        DestroyContext = function() step("context destroy") end,
      }
      package.loaded.timer = saved.timer
      -- imguikit holds the timer module, so patch the method temporarily.
      local timer = require "timer"
      local original_now = timer.now
      timer.now = function() clock = clock + (tick or 0.002); return clock end
      opts = opts or {}
      opts.frames = 1
      opts.draw = function() step("draw") end
      local code, detail = kit.run(opts)
      timer.now = original_now
      return code, detail, table.concat(calls, ","), sleeps
    end

    local suffix = "renderer shutdown,platform shutdown,context destroy,window destroy,terminate"
    for _, stage in ipairs({ "events", "clear", "new frame", "draw", "render", "swap" }) do
      local code, detail, calls = exercise(stage)
      t:eq(code, nil, stage .. " failure is returned")
      t:truthy(detail:find("injected " .. stage, 1, true), stage .. " preserves cause")
      t:eq(calls:sub(-#suffix), suffix, stage .. " releases all resources in reverse order")
    end
    for _, case in ipairs({
      { "glfw init", "terminate" },
      { "window create", "terminate" },
      { "context create", "window destroy,terminate" },
      { "platform init", "context destroy,window destroy,terminate" },
      { "platform false", "context destroy,window destroy,terminate" },
      { "renderer init", "platform shutdown,context destroy,window destroy,terminate" },
      { "renderer false", "platform shutdown,context destroy,window destroy,terminate" },
    }) do
      local code, _, calls = exercise(case[1])
      t:eq(code, nil, case[1] .. " failure is returned")
      t:eq(calls:sub(-#case[2]), case[2], case[1] .. " cleans initialized resources only")
    end
    local code, _, calls = exercise("renderer shutdown")
    t:eq(code, nil, "cleanup failure is returned")
    t:eq(calls:sub(-#suffix), suffix, "cleanup continues after shutdown error")
    local success, _, _, sleeps = exercise(nil)
    t:eq(success, 0, "normal lifecycle succeeds")
    t:eq(#sleeps, 0, "VSync adds no software sleep")
    local _, _, _, limited = exercise(nil, { vsync = 0 })
    t:truthy(#limited == 1 and limited[1] > 0 and limited[1] < 16,
      "software limit subtracts work time")
    local _, _, _, slow = exercise(nil, { vsync = 0 }, 0.02)
    t:eq(#slow, 0, "over-budget frames add no sleep")
    local _, _, _, unlimited = exercise(nil, { vsync = 0, dont_sleep = true })
    t:eq(#unlimited, 0, "smoke can disable software limit")
    t:eq(kit.run { draw = function() end, fps = 0 }, nil, "invalid FPS is rejected")
    t:eq(kit.run { draw = function() end, fps = 0 / 0 }, nil, "NaN FPS is rejected")
  end)
  kit.available = available
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  t:truthy(ok, "lifecycle tests complete: " .. tostring(err))
end

return M
