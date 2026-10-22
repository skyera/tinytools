-- GUI metadata only; tool implementations remain headless and lazily loaded.
local ffi = require "ffi"
local M = {}
local schemas = {
  ["data.json"] = {
    { "mode", "Mode", { "pretty", "minify", "validate" } },
    { "indent", "Indent", 2, 0, 8 }, { "sort", "Sort keys", true },
  },
  ["data.base64"] = {
    { "decode", "Decode", false }, { "urlsafe", "URL-safe", false },
    { "pad", "Padding", true },
  },
  ["num.base"] = {
    { "time", "Conversion", { "number", "epoch", "iso" },
      labels = "Number base\0Epoch to ISO\0ISO to epoch\0" },
    { "from", "From base", 10, 2, 36 }, { "to", "To base", 16, 2, 36 },
  },
  ["hash.crc32"] = { { "algo", "Algorithm", { "crc32", "adler32" } } },
  ["gen.uuid"] = { { "count", "Count", 1, 1, 10000 } },
}

function M.new(id)
  local controls = {}
  for _, field in ipairs(schemas[id] or {}) do
    local default = field[3]
    local kind = type(default)
    controls[field[1]] = ffi.new(kind == "boolean" and "bool[1]" or "int[1]",
      kind == "table" and 0 or default)
  end
  return controls
end

function M.values(id, controls)
  local opts = {}
  for _, field in ipairs(schemas[id] or {}) do
    local value = controls[field[1]][0]
    opts[field[1]] = type(field[3]) == "table" and field[3][value + 1] or value
  end
  return opts
end

function M.draw(ig, id, controls)
  local changed = false
  for _, field in ipairs(schemas[id] or {}) do
    local key, label, default = field[1], field[2], field[3]
    -- The base fields apply only to number conversion.
    if not ((key == "from" or key == "to") and controls.time[0] ~= 0) then
      ig.SetNextItemWidth(180)
      local value = controls[key]
      local edited
      if type(default) == "table" then
        edited = ig.Combo_Str(label, value, field.labels or (table.concat(default, "\0") .. "\0"))
      elseif type(default) == "boolean" then
        edited = ig.Checkbox(label, value)
      else
        edited = ig.InputInt(label, value)
        value[0] = math.max(field[4], math.min(field[5], value[0]))
      end
      changed = edited or changed
    end
  end
  return changed
end

return M
