-- data.json: validate, pretty-print and minify JSON.
-- Decoding is rxi's json.lua (vendored as lib/json.lua); pretty printing is
-- ours so the output is deterministic (sorted keys, fixed two-space indent).

local json = require "json"

local M = { id = "data.json" }

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function quote(s)
  local body = s:gsub('[%z\1-\31"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. body .. '"'
end

local function number(v)
  if v ~= v or v == math.huge or v == -math.huge then return nil end
  if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
    return string.format("%d", v)
  end
  return string.format("%.14g", v)
end

local function is_array(v)
  local n = 0
  for k in pairs(v) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  for i = 1, n do
    if v[i] == nil then return false end
  end
  return true, n
end

local encode

function encode(v, indent, sort_keys, depth)
  local kind = type(v)

  if v == nil or (json.null ~= nil and v == json.null) then return "null" end
  if kind == "boolean" then return tostring(v) end
  if kind == "number" then
    local out = number(v)
    if not out then error("cannot encode non-finite number") end
    return out
  end
  if kind == "string" then return quote(v) end
  if kind ~= "table" then error("cannot encode value of type " .. kind) end

  local nl = indent and "\n" or ""
  local sep = indent and ",\n" or ","
  local inner = indent and string.rep(" ", indent * (depth + 1)) or ""
  local outer = indent and string.rep(" ", indent * depth) or ""

  local array, n = is_array(v)
  local parts = {}

  if array then
    for i = 1, n do
      parts[i] = inner .. encode(v[i], indent, sort_keys, depth + 1)
    end
    if n == 0 then return "[]" end
    return "[" .. nl .. table.concat(parts, sep) .. nl .. outer .. "]"
  end

  local entries = {}
  for k, val in pairs(v) do
    local key = type(k) == "string" and k or tostring(k)
    entries[#entries + 1] = { key = key, value = val }
  end
  if sort_keys then
    table.sort(entries, function(a, b) return a.key < b.key end)
  end
  for i, e in ipairs(entries) do
    parts[i] = inner .. quote(e.key) .. (indent and ": " or ":")
      .. encode(e.value, indent, sort_keys, depth + 1)
  end
  if #entries == 0 then
    -- is_array() already claimed an empty table, so this only happens when
    -- keys were filtered out; keep the object form.
    return "{}"
  end
  return "{" .. nl .. table.concat(parts, sep) .. nl .. outer .. "}"
end

local function strip_location(msg)
  -- Drops the leading "path:line: " that pcall adds; paths may contain ':',
  -- so match up to the first `:<digits>:` instead of the first ':'.
  return (tostring(msg):gsub("^.-:%d+:%s*", ""))
end

local function decode(input)
  local ok, value = pcall(json.decode, input)
  if ok then return value end
  local msg = tostring(value)
  msg = msg:gsub("^.-:%d+:%s*", "")
  return nil, msg
end

function M.run(input, opts)
  opts = opts or {}
  input = input or ""
  local mode = opts.mode or "pretty"

  if mode == "validate" then
    local _, err = decode(input)
    if err then return nil, "invalid JSON: " .. err end
    return { text = "valid JSON", json = { valid = true, bytes = #input } }
  end

  local value, err = decode(input)
  if err then return nil, "invalid JSON: " .. err end

  local sort_keys = opts.sort ~= false and opts.sort ~= "false" and opts.sort ~= "0"
  local text
  if mode == "minify" then
    -- Our encoder, not json.encode: json.encode iterates with pairs(), so its
    -- key order changes between processes and would make output non-reproducible.
    local ok, out = pcall(encode, value, nil, sort_keys, 0)
    if not ok then return nil, "cannot encode: " .. strip_location(out) end
    text = out
  elseif mode == "pretty" then
    local indent = tonumber(opts.indent) or 2
    if indent < 0 or indent > 8 then return nil, "indent must be 0..8" end
    local ok, out = pcall(encode, value, indent > 0 and indent or nil, sort_keys, 0)
    if not ok then return nil, "cannot encode: " .. strip_location(out) end
    text = out
  else
    return nil, "unknown mode '" .. tostring(mode) .. "' (pretty, minify, validate)"
  end

  return {
    text = text,
    json = { mode = mode, bytes = #input, output_bytes = #text },
  }
end

function M.selftest(t)
  local pretty = M.run('{"b":1,"a":[1,2,{"z":null}]}')
  t:truthy(pretty and pretty.text:find("\n"), "pretty output is multi-line")
  t:truthy(pretty and pretty.text:find('"a"') < pretty.text:find('"b"'), "keys sorted")
  t:eq(pretty.text, [[
{
  "a": [
    1,
    2,
    {
      "z": null
    }
  ],
  "b": 1
}]], "pretty output exact")

  local minified = M.run('{ "a" : 1 , "b" : [ 2, 3 ] }', { mode = "minify" })
  t:eq(minified.text, '{"a":1,"b":[2,3]}', "minify")

  local validated = M.run('{"ok":true}', { mode = "validate" })
  t:eq(validated.text, "valid JSON", "validate ok")

  local bad, err = M.run('{"a":}', { mode = "validate" })
  t:eq(bad, nil, "validate rejects malformed")
  t:truthy(err and err:find("invalid JSON"), "validate error message")
  t:truthy(err and err:find("line"), "error carries line/col")

  local trailing, terr = M.run('[1,2] junk')
  t:eq(trailing, nil, "trailing garbage rejected")
  t:truthy(terr and terr:find("trailing"), "trailing message")

  local escaped = M.run('{"s":"line\\nbreak \\u00e9"}', { mode = "minify" })
  t:eq(escaped.text, '{"s":"line\\nbreak \195\169"}', "controls and unicode escapes")

  local numbers = M.run('[1, 1.5, -0.25, 1e3]', { mode = "minify" })
  t:eq(numbers.text, '[1,1.5,-0.25,1000]', "numbers")

  local nested = M.run('{"a":{"b":{"c":[[]]}}}', { mode = "minify" })
  t:eq(nested.text, '{"a":{"b":{"c":[[]]}}}', "empty containers")

  local indent0 = M.run('{"a":1}', { indent = 0 })
  t:eq(indent0.text, '{"a":1}', "indent 0 behaves like minify")

  local badmode, merr = M.run("{}", { mode = "nope" })
  t:eq(badmode, nil, "unknown mode rejected")
  t:truthy(merr and merr:find("unknown mode"), "unknown mode message")
end

return M
