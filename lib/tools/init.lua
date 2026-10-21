-- Tool registry: metadata only, so the shell can search and group tools without
-- loading their code. Behaviour lives in lib/tools/<id with dots as underscores>.lua.
--
-- Adding a tool means adding an entry here plus the module; tests/test_registry.lua
-- fails if the two drift apart.

return {
  {
    id = "data.json",
    group = "Data",
    name = "JSON",
    keywords = { "json", "pretty", "minify", "validate", "format", "sort" },
    order = 10,
  },
  {
    id = "data.base64",
    group = "Data",
    name = "Base64",
    keywords = { "base64", "b64", "encode", "decode", "urlsafe", "url-safe" },
    order = 20,
  },
  {
    id = "num.base",
    group = "Converters",
    name = "Number base / time",
    keywords = { "base", "radix", "hex", "binary", "octal", "epoch", "iso8601", "time", "timestamp" },
    order = 30,
  },
  {
    id = "hash.crc32",
    group = "Generators",
    name = "CRC32 / Adler32",
    keywords = { "hash", "checksum", "crc", "crc32", "adler", "adler32" },
    order = 40,
  },
  {
    id = "gen.uuid",
    group = "Generators",
    name = "UUID v4",
    keywords = { "uuid", "guid", "random", "id", "v4" },
    order = 50,
  },
}
