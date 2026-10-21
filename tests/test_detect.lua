-- Smart-paste detectors: known samples, ambiguity, and the invariant that every
-- suggested tool actually exists in the registry.

local detect = require "detect"
local registry = require "tools"

local M = {}

local function in_registry(id)
  for _, entry in ipairs(registry) do
    if entry.id == id then return true end
  end
  return false
end

function M.run(t)
  local json_hits = detect.detect('{"a":1,"b":[2,3]}')
  t:truthy(#json_hits >= 1, "json detected")
  t:eq(json_hits[1].tool, "data.json", "json maps to data.json")
  t:truthy(json_hits[1].hint:find("JSON") ~= nil, "json hint text")

  local b64_hits = detect.detect("aGVsbG8=")
  t:eq(#b64_hits, 1, "base64 is a single match")
  t:eq(b64_hits[1].tool, "data.base64", "base64 maps to data.base64")

  local uuid = "d3b1e5f0-1c2a-4a7b-9c3d-2e4f5a6b7c8d"
  local uuid_hits = detect.detect(uuid)
  t:eq(uuid_hits[1].tool, "gen.uuid", "uuid maps to gen.uuid")
  t:truthy(uuid_hits[1].hint:find("UUID") ~= nil, "uuid hint text")

  local epoch_hits = detect.detect("1792454400")
  t:eq(epoch_hits[1].tool, "num.base", "epoch maps to num.base")
  t:truthy(epoch_hits[1].hint:find("epoch seconds") ~= nil, "epoch seconds hint")

  local ms_hits = detect.detect("1792454400123")
  t:truthy(ms_hits[1].hint:find("milliseconds") ~= nil, "epoch milliseconds hint")

  -- No false positives on ordinary text.
  t:eq(#detect.detect("hello world"), 0, "plain text is not detected")
  t:eq(#detect.detect(""), 0, "empty text is not detected")
  t:eq(#detect.detect("   \n\t "), 0, "whitespace is not detected")
  t:eq(#detect.detect("{not json"), 0, "malformed json is not detected")
  t:eq(#detect.detect("12345"), 0, "short digits are not an epoch")

  -- one() only answers when the answer is unambiguous.
  t:eq(detect.one("1792454400").tool, "num.base", "one() returns the sole match")
  t:eq(detect.one("hello world"), nil, "one() returns nil without a match")

  -- Every suggestion must point at a tool that exists.
  local samples = {
    '{"a":1}',
    "aGVsbG8=",
    uuid,
    "1792454400",
    "1792454400123",
    "[1,2,3]",
    "Zm9vYmFy",
  }
  local suggestions = 0
  for _, sample in ipairs(samples) do
    for _, hit in ipairs(detect.detect(sample)) do
      suggestions = suggestions + 1
      t:truthy(in_registry(hit.tool), "suggested tool exists: " .. tostring(hit.tool))
    end
  end
  t:truthy(suggestions >= #samples, "samples produce suggestions")
end

return M
