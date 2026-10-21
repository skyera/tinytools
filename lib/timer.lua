-- Monotonic clock for the whole repo: timer.now() returns seconds as a float.
-- Uses QueryPerformanceCounter on Windows, clock_gettime(CLOCK_MONOTONIC) on
-- POSIX, and falls back to os.clock (CPU time) if neither is available.

local ffi = require "ffi"

local M = {}

local now

do
  if ffi.os == "Windows" then
    local ok = pcall(ffi.cdef, [[
      typedef union {
        struct { uint32_t LowPart; int32_t HighPart; } u;
        int64_t QuadPart;
      } tt_large_int;
      int32_t QueryPerformanceCounter(tt_large_int *lpPerformanceCount);
      int32_t QueryPerformanceFrequency(tt_large_int *lpFrequency);
    ]])
    local loaded, k32 = pcall(ffi.load, "kernel32")
    if ok and loaded then
      local freq = ffi.new("tt_large_int")
      if k32.QueryPerformanceFrequency(freq) ~= 0 and tonumber(freq.QuadPart) > 0 then
        local per_second = tonumber(freq.QuadPart)
        local counter = ffi.new("tt_large_int")
        now = function()
          k32.QueryPerformanceCounter(counter)
          return tonumber(counter.QuadPart) / per_second
        end
      end
    end
  else
    local ok = pcall(ffi.cdef, [[
      typedef struct { int64_t tv_sec; int64_t tv_nsec; } tt_timespec;
      int clock_gettime(int clk_id, tt_timespec *tp);
    ]])
    if ok then
      local CLOCK_MONOTONIC = 1
      local ts = ffi.new("tt_timespec")
      local C = ffi.C
      local works = pcall(function() return C.clock_gettime(CLOCK_MONOTONIC, ts) end)
      if works then
        now = function()
          C.clock_gettime(CLOCK_MONOTONIC, ts)
          return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
        end
      end
    end
  end
end

if not now then
  now = function() return os.clock() end
  M.fallback = true
end

function M.now()
  return now()
end

-- Run fn(...) and return elapsed milliseconds (plus whatever fn returned is
-- discarded; callers keep their own values).
function M.ms(fn, ...)
  local t0 = now()
  fn(...)
  return (now() - t0) * 1000
end

return M
