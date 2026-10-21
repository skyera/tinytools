-- num.base: base 2..36 conversion, plus epoch <-> ISO 8601 (UTC).
-- Time conversion is done with civil-date arithmetic so it never depends on the
-- host timezone; selftest cross-checks formatting against os.date("!...", n).

local M = { id = "num.base" }

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local DIGIT_VALUE = {}
for i = 1, #DIGITS do DIGIT_VALUE[DIGITS:sub(i, i)] = i - 1 end

local MAX_SAFE = 2 ^ 53

------------------------------------------------------------------- integers

local function parse_int(s, base)
  if base < 2 or base > 36 or base ~= math.floor(base) then
    return nil, "base must be an integer in 2..36"
  end

  local sign, body = 1, s
  if s:sub(1, 1) == "-" then
    sign, body = -1, s:sub(2)
  elseif s:sub(1, 1) == "+" then
    body = s:sub(2)
  end
  if body == "" then return nil, "empty number" end

  local n = 0
  for i = 1, #body do
    local d = DIGIT_VALUE[body:sub(i, i):lower()]
    if not d then return nil, "invalid digit '" .. body:sub(i, i) .. "' for base " .. base end
    if d >= base then return nil, "digit '" .. body:sub(i, i) .. "' is out of range for base " .. base end
    n = n * base + d
    if n >= MAX_SAFE then return nil, "number exceeds 2^53" end
  end
  return sign * n
end

local function to_int(n, base)
  if base < 2 or base > 36 or base ~= math.floor(base) then
    return nil, "base must be an integer in 2..36"
  end
  if n ~= math.floor(n) then return nil, "only integers convert between bases" end
  if n == 0 then return "0" end

  local sign = ""
  if n < 0 then
    sign, n = "-", -n
  end
  local out = {}
  while n > 0 do
    local d = n % base
    out[#out + 1] = DIGITS:sub(d + 1, d + 1)
    n = math.floor(n / base)
  end
  return sign .. table.concat(out):reverse()
end

------------------------------------------------------------------------ time

-- Days since 1970-01-01 <-> proleptic Gregorian date (Howard Hinnant's
-- days_from_civil / civil_from_days).
local function days_from_civil(y, m, d)
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
    - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  return y + (m <= 2 and 1 or 0), m, d
end

function M.iso_from_epoch(n)
  local secs = math.floor(n)
  local days = math.floor(secs / 86400)
  local rem = secs - days * 86400
  local y, m, d = civil_from_days(days)
  return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d,
    math.floor(rem / 3600), math.floor(rem / 60) % 60, rem % 60)
end

function M.epoch_from_iso(s)
  local y, m, d, hh, mm, ss = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)Z?$")
  if not y then
    y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    hh, mm, ss = "00", "00", "00"
  end
  if not y then return nil, "expected YYYY-MM-DD[THH:MM:SSZ]" end

  y, m, d, hh, mm, ss = tonumber(y), tonumber(m), tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss)
  if m < 1 or m > 12 or d < 1 or d > 31 then return nil, "date out of range" end
  if hh > 23 or mm > 59 or ss > 60 then return nil, "time out of range" end

  return days_from_civil(y, m, d) * 86400 + hh * 3600 + mm * 60 + ss
end

------------------------------------------------------------------- run

function M.run(input, opts)
  opts = opts or {}
  local s = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")

  if opts.time == "iso" or opts.time == "from-iso" then
    local n, err = M.epoch_from_iso(s)
    if not n then return nil, err end
    return { text = string.format("%d", n), json = { epoch = n, iso = M.iso_from_epoch(n) } }
  end

  if opts.time == "epoch" or opts.time == "from-epoch" then
    local n = tonumber(s)
    if not n then return nil, "not a number: " .. s end
    local iso = M.iso_from_epoch(n)
    return { text = iso, json = { epoch = math.floor(n), iso = iso } }
  end

  local from = tonumber(opts.from) or 10
  -- With only `from` given, decimal is the obvious target; otherwise hex.
  local to = tonumber(opts.to) or (from ~= 10 and 10 or 16)

  local n, err = parse_int(s, from)
  if not n then return nil, err end
  local out, terr = to_int(n, to)
  if not out then return nil, terr end

  return {
    text = out,
    json = { value = n, base = to, hex = to_int(n, 16), bin = to_int(n, 2) },
  }
end

function M.selftest(t)
  t:eq(M.run("255").text, "ff", "10 -> 16")
  t:eq(M.run("ff", { from = 16 }).text, "255", "16 -> 10")
  t:eq(M.run("ff", { from = 16, to = 2 }).text, "11111111", "16 -> 2")
  t:eq(M.run("1111", { from = 2, to = 10 }).text, "15", "2 -> 10")
  t:eq(M.run("zz", { from = 36, to = 10 }).text, "1295", "36 -> 10")
  t:eq(M.run("-255").text, "-ff", "negative")
  t:eq(M.run("0").text, "0", "zero")
  t:eq(M.run("0", { to = 2 }).text, "0", "zero in base 2")
  t:eq(M.run("1000").json.hex, "3e8", "hex in json result")

  local bad, err = M.run("2", { from = 2 })
  t:eq(bad, nil, "digit out of range rejected")
  t:truthy(err and err:find("out of range"), "digit error message")

  local badbase, berr = M.run("1", { from = 37 })
  t:eq(badbase, nil, "base 37 rejected")
  t:truthy(berr and berr:find("2..36"), "base error message")

  t:eq(M.iso_from_epoch(0), "1970-01-01T00:00:00Z", "epoch 0")
  t:eq(M.epoch_from_iso("1970-01-01T00:00:00Z"), 0, "iso 0")
  t:eq(M.iso_from_epoch(86399), "1970-01-01T23:59:59Z", "end of first day")
  t:eq(M.epoch_from_iso("2026-10-20"), 1792454400, "date only")

  -- Formatter must agree with the C library's UTC formatting.
  local mismatches = 0
  for _, n in ipairs({ 0, 1, 951782400, 1234567890, 1792454400, 2147483647, 4102444800 }) do
    if os.date("!%Y-%m-%dT%H:%M:%SZ", n) ~= M.iso_from_epoch(n) then
      mismatches = mismatches + 1
      t:fail("os.date mismatch at " .. n)
    end
  end
  t:eq(mismatches, 0, "iso formatter matches os.date")

  local round = M.epoch_from_iso("2000-02-29T12:34:56Z")
  t:eq(M.iso_from_epoch(round), "2000-02-29T12:34:56Z", "leap day round trip")
  t:eq(M.run(tostring(round), { time = "epoch" }).text, "2000-02-29T12:34:56Z", "epoch -> iso run")
  t:eq(M.run("2000-02-29T12:34:56Z", { time = "iso" }).text, tostring(round), "iso -> epoch run")

  local badiso, ierr = M.run("31-12-2000", { time = "iso" })
  t:eq(badiso, nil, "malformed iso rejected")
  t:truthy(ierr and ierr:find("expected"), "iso error message")
end

return M
