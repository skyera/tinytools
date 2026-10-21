-- data.base64: Base64 text encode/decode (standard and URL-safe alphabets).

local M = { id = "data.base64" }

local STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local byte_std, byte_url = {}, {}
local value_of = {}

for i = 1, 64 do
  byte_std[i - 1] = STD:byte(i)
  byte_url[i - 1] = URL:byte(i)
  value_of[STD:sub(i, i)] = i - 1
  value_of[URL:sub(i, i)] = i - 1
end

local function flag(v, default)
  if v == nil then return default end
  if v == false or v == "false" or v == "0" or v == 0 then return false end
  return true
end

local function encode(s, urlsafe, pad)
  local alpha = urlsafe and byte_url or byte_std
  local out = {}
  local n = #s
  local i = 1

  while i + 2 <= n do
    local a, b, c = s:byte(i, i + 2)
    local v = a * 65536 + b * 256 + c
    out[#out + 1] = string.char(
      alpha[math.floor(v / 262144)],
      alpha[math.floor(v / 4096) % 64],
      alpha[math.floor(v / 64) % 64],
      alpha[v % 64])
    i = i + 3
  end

  local rest = n - i + 1
  if rest == 1 then
    local a = s:byte(i)
    out[#out + 1] = string.char(alpha[math.floor(a / 4)], alpha[(a % 4) * 16])
    if pad then out[#out + 1] = "==" end
  elseif rest == 2 then
    local a, b = s:byte(i, i + 1)
    local v = a * 256 + b
    out[#out + 1] = string.char(
      alpha[math.floor(v / 1024)],
      alpha[math.floor(v / 16) % 64],
      alpha[(v % 16) * 4])
    if pad then out[#out + 1] = "=" end
  end

  return table.concat(out)
end

local function decode(s)
  local clean = s:gsub("%s+", "")
  if not clean:match("^[A-Za-z0-9%+/_%-]*=?=?$") then
    return nil, "invalid base64 character"
  end

  local body = clean:gsub("=+$", "")
  if #body % 4 == 1 then
    return nil, "invalid base64 length"
  end

  local out = {}
  local i = 1

  while i + 3 <= #body do
    local v = 0
    for j = 0, 3 do
      local d = value_of[body:sub(i + j, i + j)]
      if not d then return nil, "invalid base64 character" end
      v = v * 64 + d
    end
    out[#out + 1] = string.char(
      math.floor(v / 65536) % 256,
      math.floor(v / 256) % 256,
      v % 256)
    i = i + 4
  end

  local rest = #body - i + 1
  if rest == 2 then
    local d1 = value_of[body:sub(i, i)]
    local d2 = value_of[body:sub(i + 1, i + 1)]
    if not d1 or not d2 then return nil, "invalid base64 character" end
    out[#out + 1] = string.char(math.floor((d1 * 64 + d2) / 16))
  elseif rest == 3 then
    local d1 = value_of[body:sub(i, i)]
    local d2 = value_of[body:sub(i + 1, i + 1)]
    local d3 = value_of[body:sub(i + 2, i + 2)]
    if not d1 or not d2 or not d3 then return nil, "invalid base64 character" end
    local v = d1 * 4096 + d2 * 64 + d3
    out[#out + 1] = string.char(math.floor(v / 1024) % 256, math.floor(v / 4) % 256)
  end

  return table.concat(out)
end

function M.run(input, opts)
  opts = opts or {}
  input = input or ""

  if flag(opts.decode, false) then
    local out, err = decode(input)
    if not out then return nil, err end
    return { text = out, json = { decoded = true, bytes = #out } }
  end

  local urlsafe = flag(opts.urlsafe, false)
  local pad = flag(opts.pad, true)
  local out = encode(input, urlsafe, pad)
  return { text = out, json = { encoded = true, bytes = #input, urlsafe = urlsafe, pad = pad } }
end

function M.selftest(t)
  -- RFC 4648 test vectors.
  local vectors = {
    { "", "" },
    { "f", "Zg==" },
    { "fo", "Zm8=" },
    { "foo", "Zm9v" },
    { "foob", "Zm9vYg==" },
    { "fooba", "Zm9vYmE=" },
    { "foobar", "Zm9vYmFy" },
  }
  for _, v in ipairs(vectors) do
    t:eq(M.run(v[1]).text, v[2], "encode " .. string.format("%q", v[1]))
    t:eq(M.run(v[2], { decode = true }).text, v[1], "decode " .. v[2])
  end

  -- Every byte value survives a round trip.
  local all = {}
  for i = 0, 255 do all[#all + 1] = string.char(i) end
  all = table.concat(all)
  local encoded = M.run(all).text
  t:eq(#all, 256, "byte alphabet built")
  t:eq(M.run(encoded, { decode = true }).text, all, "256-byte round trip")

  -- URL-safe alphabet, with and without padding.
  local raw = string.char(0xfb, 0xff)
  t:eq(M.run(raw).text, "+/8=", "standard alphabet")
  t:eq(M.run(raw, { urlsafe = true }).text, "-_8=", "url-safe alphabet")
  t:eq(M.run(raw, { urlsafe = true, pad = false }).text, "-_8", "url-safe unpadded")
  t:eq(M.run("-_8", { decode = true }).text, raw, "decode url-safe unpadded")

  -- Whitespace is tolerated on decode, invalid characters are not.
  t:eq(M.run("Zm9v\nYmFy", { decode = true }).text, "foobar", "decode with newline")
  local bad, err = M.run("Zm9v!!!!", { decode = true })
  t:eq(bad, nil, "invalid character rejected")
  t:truthy(err and err:find("invalid base64 character"), "invalid character message")
  local bad2, err2 = M.run("Z", { decode = true })
  t:eq(bad2, nil, "impossible length rejected")
  t:truthy(err2 and err2:find("length"), "length message")

  t:eq(M.run("").text, "", "empty encodes to empty")
  t:eq(M.run("", { decode = true }).text, "", "empty decodes to empty")
end

return M
