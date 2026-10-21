-- Clipboard detectors for smart paste. Pure functions: given text, return the
-- tools that could consume it, best first. Only tools that exist in the registry
-- are reported; tests/test_detect.lua enforces that.

local json = require "json"
local base64 = require "tools.data_base64"

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local detectors = {}

local function add(fn)
  detectors[#detectors + 1] = fn
end

-- JSON: parses, and starts with a container (so "42" is not "JSON").
add(function(s)
  if #s < 2 then return nil end
  local first = s:sub(1, 1)
  if first ~= "{" and first ~= "[" then return nil end
  local ok = pcall(json.decode, s)
  if not ok then return nil end
  return { tool = "data.json", hint = "looks like JSON", confidence = 0.95 }
end)

-- UUID v4 (any version digit accepted; the shape is what we match).
add(function(s)
  if s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
    return { tool = "gen.uuid", hint = "looks like a UUID", confidence = 0.9 }
  end
end)

-- Epoch seconds or milliseconds: digits only, and inside a plausible window.
add(function(s)
  if not s:match("^%d+$") then return nil end
  local n = tonumber(s)
  if not n then return nil end
  local secs
  if #s == 13 then
    secs = n / 1000
  elseif #s == 10 then
    secs = n
  else
    return nil
  end
  if secs < 315532800 or secs > 4102444800 then return nil end -- 1980..2100
  local hint = (#s == 13) and "epoch milliseconds" or "epoch seconds"
  return { tool = "num.base", hint = hint, confidence = 0.6 }
end)

-- Base64: decodes cleanly, has plausible length, and is not pure words.
add(function(s)
  if #s < 8 or #s % 4 ~= 0 then return nil end
  if not s:match("^[A-Za-z0-9%+/_%-]+=?=?$") then return nil end
  local out = base64.run(s, { decode = true })
  if not out or #out.text < 4 then return nil end
  if out.text:find("%z") then return nil end -- NUL bytes: probably not text
  return { tool = "data.base64", hint = "looks like Base64", confidence = 0.7 }
end)

function M.detect(text)
  local results = {}
  if type(text) ~= "string" then return results end
  local s = trim(text)
  if s == "" then return results end

  for _, fn in ipairs(detectors) do
    local hit = fn(s)
    if hit then
      hit.text = s
      results[#results + 1] = hit
    end
  end

  table.sort(results, function(a, b) return a.confidence > b.confidence end)
  return results
end

-- The single best match, or nil when there is none or it is ambiguous.
function M.one(text)
  local all = M.detect(text)
  if #all == 1 then return all[1] end
  if #all > 1 and all[1].confidence > all[2].confidence + 0.15 then return all[1] end
  return nil
end

return M
