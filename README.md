```text
   __  _             __              __
  / /_(_)___  __  __/ /_____  ____  / /____
 / __/ / __ \/ / / / __/ __ \/ __ \/ / ___/
/ /_/ / / / / /_/ / /_/ /_/ / /_/ / (__  )
\__/_/_/ /_/\__, /\__/\____/\____/_/____/
           /____/
```

A tiny toolbox for LuaJIT developers — many small offline tools in one Dear
ImGui window, every one of them also callable from the command line.

Status: **M2 done** — the window works (`make libs`, then `make run` or
`make smoke`). Tool coverage is M3; see [PLAN.md](PLAN.md).

```text
$ make run
┌─ tinytools ─────────────────────────────────────────────── [−] [□] [×] ┐
│ search tools...        [ ] favorites only                              │
├──────────────────┬─────────────────────────────────────────────────────┤
│ Data             │ JSON                                                │
│   JSON           │ Mode [pretty v]  Indent [2]  [x] Sort keys           │
│   Base64         │ ┌─────────────────────────────────────────────────┐ │
│ Converters       │ │ { "b": 1, "a": [1, 2, null] }                   │ │
│   Number base    │ └─────────────────────────────────────────────────┘ │
│ Generators       │ [Run] [Clear] [Copy output]                         │
│   CRC32          │ {"a":[1,2,null],"b":1}                              │
│   UUID v4        │                                                     │
├──────────────────┴─────────────────────────────────────────────────────┤
│ 5 tools | LuaJIT 2.1 | imgui 1.93 | FPS 60                             │
└────────────────────────────────────────────────────────────────────────┘
```

## Quick start

```bash
git clone --recurse-submodules <url> tinytools && cd tinytools

make test     # headless suite: no ImGui, no display needed
make libs     # builds GLFW + the cimgui binding into build/out
make run      # the window
make smoke    # 300 frames in a hidden window, exits 0
make test-gui # GUI interaction checks in a hidden window
```

Everything works offline. The CLI is the same code the GUI calls:

```bash
luajit apps/toolbox.lua --list
luajit apps/toolbox.lua --run data.base64 --text hello
luajit apps/toolbox.lua --run data.json --text '{"b":1,"a":null}' --opt mode=minify
luajit apps/toolbox.lua --run num.base --text 1792454400 --opt time=epoch
luajit apps/toolbox.lua --check      # dependencies + every selftest
```

Exit codes: `0` success · `1` tool/selftest/argument failure · `3` GUI
requested but the binding is unavailable.

The GUI has tool-specific dropdowns, checkboxes and numeric controls. Press
**Ctrl+Enter** to run the selected tool, use **Paste** to replace its input,
and select text in the read-only output pane or use **Copy output**. Input and
output scroll independently; output wrapping can be toggled. The input limit
is 65,535 bytes; the Paste button rejects larger clipboard contents without
changing the input. Decoded NUL bytes appear as `\0` in the output preview and
cannot be copied through the text clipboard.

Source runs and folder bundles save favorites to `state/settings.json` beside
the application. Favorites survive restarts; a settings read/write failure
appears in the GUI. The folder must be writable to save settings. The single
EXE uses the separate per-user location described below.

## What is where

```text
apps/toolbox.lua        entry point (paths + cli.main)
lib/cli.lua             arguments, dispatch, selftest runner
lib/imguikit.lua        the only code that knows build/out: loads the binding,
                        opens the window, applies DPI, always shuts down
lib/shell.lua           sidebar (search, groups, favorites) + tool panel
lib/tool_options.lua    GUI option controls for the five tools
lib/store.lua           favorites persistence with atomic settings replacement
lib/tools/init.lua      registry: id, group, name, keywords, order
lib/tools/<id>.lua      one module per tool; dots become underscores
lib/detect.lua          clipboard detectors for smart paste
lib/timer.lua           monotonic clock (QPC / clock_gettime)
lib/check.lua           assertion recorder shared by selftests and tests
lib/json.lua            rxi/json.lua 0.1.2 (MIT), patched to preserve null
scripts/install_glue.lua  post-build: glue files, runtime DLL, binding prune
tests/                  headless suites (`luajit tests/run.lua`)
```

## Tool contract

- `run(input, opts) -> { text = string, json = table }` — pure, headless,
  returns `nil, message` on bad input.
- `selftest(t)` — assertions through `lib/check.lua`.
- The shell drives `run()` with shared input/output panes and controls defined
  in `lib/tool_options.lua`; tool computation stays independent of ImGui.

## Packaging

```bash
make libs     # once, to have build/out
make dist     # -> dist/tinytools/ (about 14 MB)
```

`dist/tinytools/` is self-contained: `luajit.exe` + `lua51.dll`, the app's
`apps/` and `lib/`, the binding DLLs and glue under `build/out/`, and
`tinytools.bat`. Copy or zip the folder anywhere; no LuaJIT, CMake or
toolchain is needed on the target machine, and it runs from any working
directory.

```text
tinytools.bat                 GUI
tinytools.bat --list          same CLI as the checkout
tinytools.bat --run data.base64 --text hello
```

The bundle keeps the repo layout because `apps/toolbox.lua` and `imguikit`
resolve everything relative to their own files. `scripts/package.lua` strips
the binding DLL copy (~70 MB of RelWithDebInfo symbols); set
`TINYTOOLS_NO_STRIP=1` to keep them. Point `LUAJIT_EXE` at a specific
`luajit.exe` when the one on `PATH` is not the one you want to ship.

### Single Windows executable

```text
make exe       # -> dist/tinytools.exe
make test-exe  # integration checks for the built EXE
```

Or run `python scripts/package_exe.py` directly. Building requires Windows,
Python 3.9+, LuaJIT, MinGW-w64 `gcc` and `windres`, and the existing `make libs`
output. Set `CC`, `WINDRES`, or `LUAJIT_EXE` to select different build tools.
No packaging libraries or downloads are needed.

Distribute **only `dist/tinytools.exe`**. Double-click it to open the GUI; the
launcher does not create a console window. The same EXE accepts the CLI:

```powershell
.\dist\tinytools.exe --list | Out-Host
.\dist\tinytools.exe --run data.base64 --text hello | Out-Host
.\dist\tinytools.exe --run data.json --in input.json | Out-Host
$LASTEXITCODE
```

`Out-Host` makes PowerShell wait for this GUI-subsystem executable. Scripts
using a process API should wait for it and read its exit code. Arguments,
stdin, stdout, stderr and tool exit codes are passed through. Relative input
paths resolve against the caller's working directory. Launcher failures use
exit code `125`.

The EXE embeds a compressed bundle and uses Windows APIs to extract it; the
target needs no LuaJIT installation, compiler, Python, 7-Zip or PowerShell.
The current build targets Windows 10/11 x64 and uses their system C runtime.

```text
%LOCALAPPDATA%\tinytools\cache\<content-hash>\  extracted application files
%LOCALAPPDATA%\tinytools\state\settings.json   favorites across upgrades
%LOCALAPPDATA%\tinytools\state\imgui.ini      GUI layout
```

Every launch checks the cached files against embedded SHA-256 hashes and
repairs missing or changed files. Concurrent launches share an extraction
lock. New bundle contents get a separate cache directory while settings stay
in the same location. Older caches are retained; they can be removed when
the application is closed. Set `TINYTOOLS_HOME` to a writable location
(for example `D:\Apps\tinytools-data`) to relocate both cache and state.
The executable's own directory does not need to be writable.

## Build notes worth knowing

- The binding's `base.lua` binds some symbols *eagerly*, including features this
  CMake configuration does not compile (FreeType, cimCTE). `install_glue.lua`
  asks the DLL which symbols exist and comments out exactly the missing eager
  lines — 2 of 1481 on a default build — so the module loads. Anything not
  compiled is simply absent, and nothing in the shell calls it.
- Windows `LoadLibrary` ignores `package.cpath`, so `imguikit` prepends
  `build/out` to `PATH` before the binding loads. The MinGW runtime DLL
  (`libwinpthread-1.dll`) is copied next to the others so `build/out` is
  self-contained.
- GLFW is built from the submodule (3.4), not taken from the system: the binding
  needs `ImGui_ImplGlfw_GetContentScaleForMonitor`, which requires 3.3+.
- `data.json` output is deterministic (sorted keys, own printer); `num.base`
  does its own civil-date arithmetic so it never depends on the host timezone;
  `gen.uuid` reads OS entropy and fails loudly rather than faking randomness.

## Next

M3: `data.jwt`, `text.{case,diff,pattern,escape}`, `lua.ffi_layout`,
`lua.jitbench`, recents persisted to `state/`, smart-paste wired into
the shell, and long jobs moved off the frame loop.

## License

MIT. `lib/json.lua` is rxi/json.lua 0.1.2, MIT; bundled dependencies
(LuaJIT-ImGui, Dear ImGui, cimgui, GLFW, LuaJIT-GLFW, LuaJIT-GL) are MIT or
zlib licensed.
