-- hash.crc32: CRC32 (IEEE, reflected) and Adler32 over a string.
-- Two CRC32 implementations on purpose: a table-driven pure-Lua one and an FFI
-- one over the raw bytes. selftest asserts they agree, which is the pattern the
-- bench tool will reuse for Lua-vs-FFI comparisons.

local ffi = require "ffi"
local bit = require "bit"

local M = { id = "hash.crc32" }

local POLY = -306674912 -- 0xEDB88320 as a signed 32-bit integer

local table_lua = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if bit.band(c, 1) == 1 then
      c = bit.bxor(POLY, bit.rshift(c, 1))
    else
      c = bit.rshift(c, 1)
    end
  end
  table_lua[i] = c
end

local table_ffi = ffi.new("uint32_t[256]")
for i = 0, 255 do table_ffi[i] = table_lua[i] end

local function to_unsigned(v)
  if v < 0 then return v + 4294967296 end
  return v
end

local function crc32_lua(s)
  local crc = -1 -- 0xFFFFFFFF
  for i = 1, #s do
    crc = bit.bxor(bit.rshift(crc, 8), table_lua[bit.band(bit.bxor(crc, s:byte(i)), 0xFF)])
  end
  return to_unsigned(bit.bxor(crc, -1))
end

local function crc32_ffi(s)
  local p = ffi.cast("const uint8_t *", s)
  local n = #s
  local crc = -1
  for i = 0, n - 1 do
    crc = bit.bxor(bit.rshift(crc, 8), table_lua[bit.band(bit.bxor(crc, p[i]), 0xFF)])
  end
  return to_unsigned(bit.bxor(crc, -1))
end

local function adler32(s)
  local a, b = 1, 0
  local n = #s
  local p = ffi.cast("const uint8_t *", s)
  local i = 0
  while i < n do
    local stop = math.min(i + 5552, n)
    while i < stop do
      a = a + p[i]
      b = b + a
      i = i + 1
    end
    a = a % 65521
    b = b % 65521
  end
  return b * 65536 + a
end

M.crc32 = crc32_ffi
M.crc32_lua = crc32_lua
M.crc32_ffi = crc32_ffi
M.adler32 = adler32

function M.run(input, opts)
  opts = opts or {}
  local s = input or ""
  local crc = crc32_ffi(s)
  local adler = adler32(s)

  local text
  if opts.algo == "adler32" then
    text = string.format("%08x", adler)
  else
    text = string.format("%08x", crc)
  end

  return {
    text = text,
    json = {
      crc32 = string.format("%08x", crc),
      adler32 = string.format("%08x", adler),
      bytes = #s,
    },
  }
end

function M.selftest(t)
  -- Published check values.
  t:eq(string.format("%08x", crc32_lua("123456789")), "cbf43926", "lua crc32 vector")
  t:eq(string.format("%08x", crc32_ffi("123456789")), "cbf43926", "ffi crc32 vector")
  t:eq(string.format("%08x", crc32_lua("")), "00000000", "lua crc32 empty")
  t:eq(string.format("%08x", adler32("123456789")), "091e01de", "adler32 vector")
  t:eq(adler32(""), 1, "adler32 empty is 1")

  -- Both implementations must agree on real-ish data.
  local chunks = {
    "",
    "a",
    "The quick brown fox jumps over the lazy dog",
    string.rep("luajit", 1000),
  }
  for i, s in ipairs(chunks) do
    t:eq(crc32_ffi(s), crc32_lua(s), "implementations agree on chunk " .. i)
  end

  -- 64 KiB of every byte value, repeated.
  local pattern = {}
  for i = 0, 255 do pattern[#pattern + 1] = string.char(i) end
  local blob = string.rep(table.concat(pattern), 256)
  t:eq(#blob, 65536, "blob size")
  t:eq(crc32_ffi(blob), crc32_lua(blob), "implementations agree on 64 KiB")

  local out = M.run("abc")
  t:eq(out.text, out.json.crc32, "default text is crc32")
  t:eq(#out.text, 8, "crc32 is 8 hex digits")
  t:eq(M.run("abc", { algo = "adler32" }).text, out.json.adler32, "algo switch")
  t:eq(M.run("").json.bytes, 0, "byte count")
  t:eq(M.run("abc").json.bytes, 3, "byte count 3")
end

return M
