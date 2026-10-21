-- Entry point. Keeps only the package.path setup; everything else lives in
-- lib/cli.lua so tests can call the CLI in-process.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."

package.path = here .. "/../lib/?.lua;"
  .. here .. "/../lib/?/init.lua;"
  .. package.path

os.exit(require("cli").main(arg or {}))
