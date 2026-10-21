-- gen.uuid: UUID v4 from the OS entropy source (RtlGenRandom on Windows,
-- /dev/urandom elsewhere). No math.random fallback: a silently weak UUID is
-- worse than an honest error.

local ffi = require "ffi"
local bit = require "bit"

local M = { id = "gen.uuid" }

local random_bytes

do
  if ffi.os == "Windows" then
    local ok = pcall(ffi.cdef, [[
      int32_t SystemFunction036(void *RandomBuffer, uint32_t RandomBufferLength);
    ]])
    local loaded, advapi = pcall(ffi.load, "advapi32")
    if ok and loaded then
      local probe = ffi.new("uint8_t[1]")
      local works = pcall(function() return advapi.SystemFunction036(probe, 1) end)
      if works and advapi.SystemFunction036(probe, 1) ~= 0 then
        random_bytes = function(n)
          local buf = ffi.new("uint8_t[?]", n)
          if advapi.SystemFunction036(buf, n) == 0 then
            return nil, "RtlGenRandom failed"
          end
          return ffi.string(buf, n)
        end
      end
    end
  else
    random_bytes = function(n)
      local f = io.open("/dev/urandom", "rb")
      if not f then return nil, "/dev/urandom not available" end
      local s = f:read(n)
      f:close()
      if not s or #s ~= n then return nil, "/dev/urandom short read" end
      return s
    end
  end
end

if not random_bytes then
  random_bytes = function()
    return nil, "no OS entropy source available"
  end
end

-- Format 16 raw bytes as a v4 UUID, setting the version and variant bits.
function M.from_bytes(bytes)
  if #bytes ~= 16 then return nil, "expected 16 bytes, got " .. #bytes end

  local b = { bytes:byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0F), 0x40) -- version 4
  b[9] = bit.bor(bit.band(b[9], 0x3F), 0x80) -- RFC 4122 variant

  local hex = {}
  for i = 1, 16 do hex[i] = string.format("%02x", b[i]) end
  local h = table.concat(hex)
  return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16)
    .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end

function M.generate()
  local bytes, err = random_bytes(16)
  if not bytes then return nil, err end
  return M.from_bytes(bytes)
end

function M.run(_, opts)
  opts = opts or {}
  local count = tonumber(opts.count) or 1
  if count < 1 or count > 10000 or count ~= math.floor(count) then
    return nil, "count must be an integer in 1..10000"
  end

  local list = {}
  for i = 1, count do
    local uuid, err = M.generate()
    if not uuid then return nil, err end
    list[i] = uuid
  end

  return {
    text = table.concat(list, "\n"),
    json = { count = count, uuids = list },
  }
end

function M.selftest(t)
  local zero, err = M.from_bytes(string.rep("\0", 16))
  t:eq(zero, "00000000-0000-4000-8000-000000000000", "known bytes format")
  t:eq(err, nil, "known bytes have no error")

  local bad, baderr = M.from_bytes("too short")
  t:eq(bad, nil, "short input rejected")
  t:truthy(baderr and baderr:find("16 bytes"), "short input message")

  local uuid, gerr = M.generate()
  t:truthy(uuid ~= nil, "generate returns a uuid (" .. tostring(gerr or "") .. ")")
  t:truthy(uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"),
    "v4 shape: " .. tostring(uuid))
  t:truthy(uuid:sub(20, 20):match("[89ab]"), "variant nibble")

  local seen, dupes = {}, 0
  for _ = 1, 1000 do
    local u = M.generate()
    if seen[u] then dupes = dupes + 1 end
    seen[u] = true
  end
  t:eq(dupes, 0, "1000 generated uuids are unique")

  local three = M.run(nil, { count = 3 })
  t:eq(three.json.count, 3, "count honoured")
  t:eq(#three.json.uuids, 3, "three uuids")
  local lines = 0
  for _ in three.text:gmatch("[^\n]+") do lines = lines + 1 end
  t:eq(lines, 3, "three lines of text")

  local clamped, cerr = M.run(nil, { count = 0 })
  t:eq(clamped, nil, "count 0 rejected")
  t:truthy(cerr and cerr:find("1..10000"), "count message")

  local fractional = M.run(nil, { count = "2.5" })
  t:eq(fractional, nil, "fractional count rejected")
end

return M
