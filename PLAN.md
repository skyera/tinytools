# tinytools — Build Plan (v3, toolbox)

Supersedes `../lualab/LUAJIT_IMGUI_PLAN.md` (v1: where the work lives) and this
file's own v2 (single-app bench cockpit). The product is now a **developer
toolbox** — one window, many small offline tools, in the shape of
[DevToys](https://devtoys.app/) — with two changes that matter for a LuaJIT repo:

1. **Every tool is CLI-callable**, so the GUI is a second front end, not the only
   one. The whole tool set is testable headless, in CI, with no GL context.
2. **The tool set includes tools only a LuaJIT host can do** (FFI struct layout,
   JIT-on/off benchmark, bytecode/trace dump). Without those this is a slower
   re-implementation of `base64(1)`.

Project name: **tinytools** — a tiny toolbox for LuaJIT developers.

Status: **M1 and M2 delivered** — registry, five tools, CLI, 155 headless checks,
submodules + `make libs`, the ImGui shell and `--smoke` (300 frames, exit 0).
M3 (more tools, persisted favorites, smart-paste UI, job pattern) is next.

Build reality worth recording: upstream's `base.lua` eagerly binds symbols this
CMake configuration does not compile (FreeType, cimCTE), so `install_glue.lua`
prunes exactly the missing eager lines (2 of 1481 on a default build). Windows
`LoadLibrary` ignores `package.cpath`, so `imguikit` puts `build/out` on `PATH`
before loading the binding.

Repo: `git@github.com:skyera/tinytools.git` (renamed from `luajit-imgui-lab`;
GitHub redirects the old URL, but clones should use the new one). The local
working directory may still be named `luajit-imgui-lab`; that only affects
shell paths, and the `lualab` cross-link should point at the new URL.

Environment measured on the author's machine: LuaJIT `2.1.1720049189`,
MinGW-w64 `g++ 13.2.0` (ucrt, posix-seh), CMake `3.29.2`, Ninja,
`mingw32-make` (Strawberry), Git `2.54.0.windows.1`.

---

## 1. What changes from v2

| v2 | v3 | Why |
|---|---|---|
| one app, `bench_cockpit` | shell + tool registry; cockpit becomes tool `lua.jitbench` | A toolbox is a shell plus N independent tools; the cockpit's panels survive unchanged as one tool. |
| GUI is the product | GUI + `--run <tool>` CLI for every tool | DevToys' CLI covers "most tools that make sense"; ours covers all of them because each tool's logic is a pure function. |
| acceptance = interactive checks | acceptance = `selftest()` per tool, iterated by one test | Scales to 30 tools; no manual checklist grows. |
| — | **admission rule**: a tool ships only if the GUI does something the terminal cannot | Otherwise the toolbox becomes a thin skin over shell commands. |

Unchanged from v2 (already verified against upstream): the three submodules, the
two-step CMake chain into `build/out`, and the `package.cpath` loading contract.

---

## 2. Product shape

```text
┌─ tinytools ──────────────────────────────────────────── [−] [□] [×] ┐
│ 🔍 search tools…            ★ Favorites   ⌁ Paste: looks like a JWT  │
├──────────────────┬──────────────────────────────────────────────────┤
│ TEXT             │ JWT Decoder                              [copy]  │
│  Text case       │ ┌ header ───────────────────────────────────────┐│
│  Diff            │ │ {"alg":"HS256","typ":"JWT"}                   ││
│  Lua patterns    │ └───────────────────────────────────────────────┘│
│  Escape          │ ┌ payload ──────────────────────────────────────┐│
│ DATA             │ │ {"sub":"1234","exp":1760918400}   exp: in 3d  ││
│  JSON            │ └───────────────────────────────────────────────┘│
│  Base64          │ signature: 9f3c… (not verified)                  │
│  JWT             │                                                  │
│ CONVERTERS       │                                                  │
│  Number base     │                                                  │
│  Time / epoch    │                                                  │
│ LUAJIT           │                                                  │
│  FFI layout      │                                                  │
│  JIT bench       │                                                  │
├──────────────────┴──────────────────────────────────────────────────┤
│ 12 tools · LuaJIT 2.1 · imgui 1.92.9b · FPS 143.9 · [settings]      │
└─────────────────────────────────────────────────────────────────────┘
```

Shell responsibilities (all in `lib/shell.lua` + `lib/imguikit.lua`):
sidebar with search, collapsible groups, favorites and recents; content pane
hosting exactly one tool at a time; suggestion chip from smart paste; footer
status; settings (theme, auto-paste, font scale) persisted.

**Lazy loading is mandatory**: the shell must present a frame before any tool
module is `require`d. Opening a tool loads it then, and a load error becomes an
error pane inside the content area — never a crashed shell.

**Smart paste**: on window focus and on Ctrl+V, read `window:getClipboardString()`
and run cheap detectors (JSON, base64, JWT shape `x.y.z`, epoch, hex, CSV, file
path). Exactly one match and empty tool input → switch to that tool and fill it;
several matches → show the chip and let the user choose. Detectors are pure
functions in `lib/detect.lua`, covered by tests like any other logic.

**Slow work must not freeze the frame loop**: tools that take more than a frame
run as a coroutine fed from `draw`, with a progress bar and a Cancel button. The
bench tool is the first consumer of that pattern, not an exception to it.

---

## 3. Tool registry

`lib/tools/init.lua` holds metadata for search *without loading code*; behavior
lives in `lib/tools/<id>.lua`:

```lua
-- lib/tools/init.lua
return {
  { id = "text.case",   group = "Text",   name = "Text case",
    keywords = {"upper","lower","camel","snake"}, order = 10 },
  ...
}

-- lib/tools/text_case.lua
return {
  draw = function(ig, st) ... end,          -- ImGui, uses st for state
  run  = function(input, opts) ... end,     -- headless, returns {text=..., json=...}
  selftest = function(t) ... end,           -- asserts, used by tests
}
```

Rules:

- `run` and `selftest` never touch `imgui`, `glfw`, `ffi.C` beyond stdlib; they
  must execute with submodules missing.
- `draw` never does I/O; it reads/writes the tool's state table only.
- A registry test asserts every metadata entry has a module file and every
  module file has metadata, and that both agree on `id` — drift is a test
  failure, not a stale docs problem.
- Tools get no shared mutable state. Cross-tool data moves through clipboard or
  an explicit "send to tool" action.

---

## 4. Tool set

v1 ships 10; v2 adds the two that need textures. `run` = CLI-callable.

| id | group | What it does | Why GUI (not just CLI) | v |
|---|---|---|---|---|
| `data.json` | Data | pretty / minify / validate / sort keys | live error position while typing | 1 |
| `data.base64` | Data | text and file ↔ base64, URL-safe, padding toggle | see both directions at once | 1 |
| `data.jwt` | Data | decode header/payload, expiry countdown, alg warnings | signature and claims side by side | 1 |
| `num.base` | Converters | base 2–36, bit view, epoch ↔ ISO 8601 | all representations at once, editable any | 1 |
| `text.case` | Text | upper/lower/title/snake/camel/kebab | toggles immediate, multiple outputs | 1 |
| `text.diff` | Text | line diff (LCS) with inline emphasis | side-by-side is the whole point | 1 |
| `text.pattern` | Text | Lua-pattern tester with capture list | edit-while-matching | 1 |
| `text.escape` | Text | JSON/URL/hex/CSV escape and unescape | round-trip visible | 1 |
| `hash.crc32` | Generators | CRC32 + Adler32 (FFI), text or file | compare two inputs at once | 1 |
| `gen.uuid` | Generators | UUID v4 + monotonic counter | bulk generate and copy | 1 |
| `lua.ffi_layout` | LuaJIT | struct size, field offsets, alignment, padding map | a padding map cannot be read from a dump | 1 |
| `lua.jitbench` | LuaJIT | the Bench Cockpit (v2 §3 panels) | JIT toggle changes numbers live | 1 |
| `lua.bytecode` | LuaJIT | `-bl` style bytecode and trace dump for a snippet | scrollable, side-by-side source | 2 |
| `img.grid` | Graphics | thumbnail grid + duplicate groups | needs GL textures | 2 |

Explicitly **not** in v1: SHA-256 as a flagship (pure-Lua is too slow for large
inputs; see risks), image conversion, password generation, anything requiring
network.

---

## 5. CLI contract

```text
luajit apps/toolbox.lua                  # GUI
luajit apps/toolbox.lua --list           # id, group, name, one per line
luajit apps/toolbox.lua --list --json
luajit apps/toolbox.lua --run <id> [--json] [--in file | stdin]
luajit apps/toolbox.lua --check          # dependency probe + all selftests
luajit apps/toolbox.lua --selftest       # selftests only (no deps needed)
luajit apps/toolbox.lua --smoke 300      # hidden window, 300 frames, exit 0
luajit apps/toolbox.lua --help
```

Exit codes: `0` success · `1` tool/selftest failure or unknown id · `3` ImGui
missing when the GUI path was requested · `4` libraries present but GL/context
init failed.

`--list`, `--run`, `--selftest`, `--check` must work with `submodules/` and
`build/` deleted. The GUI path prints remediation naming `make submodules libs`.

---

## 6. Submodules

```bash
git submodule add https://github.com/sonoro1234/LuaJIT-ImGui.git   submodules/LuaJIT-ImGui
git submodule add -b lua_building https://github.com/sonoro1234/LuaJIT-GLFW.git submodules/LuaJIT-GLFW
git submodule add https://github.com/sonoro1234/LuaJIT-GL.git       submodules/LuaJIT-GL
git submodule update --init --recursive
```

| Submodule | Provides | Nested |
|---|---|---|
| `LuaJIT-ImGui` | `lua/imgui/*.lua`, CMake building `cimgui_glfw` | `cimgui` → `imgui`, `cimplot`, `cimguizmo`, `cimguizmo_quat`, `cimnodes`, `cimnodes_r` |
| `LuaJIT-GLFW` (`lua_building`) | `glfw.lua`, clipboard APIs, GLFW 3.4 sources | `GLFW` |
| `LuaJIT-GL` | `gl.lua` | — |

Pin by submodule commit; a bump is its own commit naming the imgui version.
Recursive init is mandatory (`cimgui/imgui`, `LuaJIT-GLFW/GLFW`). Deinitialised
submodules are a supported state for `make test` and `--run`. No `LuaJIT`
submodule: the binding is pure FFI.

---

## 7. Build chain (`make libs`)

```bash
cmake -S submodules/LuaJIT-GLFW -B build/glfw -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PWD/build/out" -DLUAJIT_BIN="$PWD/build/out"
cmake --build build/glfw --target install

cmake -S submodules/LuaJIT-ImGui -B build/imgui -G Ninja \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DGLFW_PATH="$PWD/build/out" \
      -DIMPL_GLFW=ON -DIMPL_OPENGL3=ON -DIMPL_OPENGL2=OFF \
      -DIMPL_SDL=OFF -DIMPL_EXTRAS=ON \
      -DLUAJIT_BIN="$PWD/build/out"
cmake --build build/imgui --target install
```

Produces `build/out/{cimgui_glfw.dll, glfw3.dll, lua/imgui/*.lua}` (Linux:
`libcimgui_glfw.so`, `libglfw.so.3`), all gitignored. `LUAJIT_BIN` is upstream's
own install variable, which is why a repo-local prefix works for both DLLs and
Lua files. Ninja is the default generator so the Strawberry `mingw32-make` never
picks a different toolchain than the winlibs `g++` on `PATH`.

**No prebuilt downloads.** `anima`'s newest release is `v0.2b` (2021-04); its
DLLs do not match today's 1.92.9b `cdefs.lua`.

---

## 8. Module loading contract

`lib/imguikit.lua` owns the only code that knows about `build/out`:

```lua
-- require_env(out_dir): idempotent prepend
--   package.path  = out_dir.."/lua/?.lua;" .. package.path
--   package.cpath = out_dir.."/?.dll;"      .. package.cpath  (lib?.so on Linux)
```

Verified resolution: `require "imgui.glfw"` → `build/out/lua/imgui/glfw.lua` →
`imgui/base.lua` → `ffi.load("cimgui_glfw")` → `package.cpath`;
`require "glfw"` → `ffi.load("glfw3")` (Windows) / `ffi.load("glfw.so.3")`;
`require "gl"` → `gl.set_loader(glfw)`. Override the directory with
`TINYTOOLS_OUT`; a system-wide install works read-only.

---

## 9. Bootstrap (`lib/imguikit.lua`)

v2 said "wrap `imgui.window`". That cannot work: `M:GLFW()` creates the window
and runs the loop internally, so there is no hidden window (`GLFW_VISIBLE` must
precede creation), no exact frame budget for `--smoke 300`, and no deterministic
stop. `imguikit` reproduces the same sequence (~70 lines, MIT, from
`lua/imgui/window.lua` and `examples/minimal_main.lua`):

```lua
kit.run{
  title = "tinytools", w = 1180, h = 720,
  visible = true,      -- false for --smoke
  vsync = 1,
  frames = nil,        -- number: stop after N frames
  draw = function(ig, ui) ... end,   -- ui: dt, fps, frame, window, kit
}
```

Owns: `require_env`, DPI (`ImGui_ImplGlfw_GetContentScaleForMonitor` +
`ScaleAllSizes` + `FontScaleDpi`, applied once), theme, pacing via
`ImGui_ImplGlfw_Sleep`, error modal, and a `pcall`-guarded shutdown that always
runs `ig_impl:destroy` → `window:destroy` → `glfw.terminate`. Docking and
multi-viewport stay off in v1. Cost recorded: must track upstream
`ImGui_ImplGlfw_*` changes; cheaper than depending on an unconfigurable loop.

---

## 10. State and settings

```text
state/settings.json      # theme, font scale, favorites, recents, auto-paste
state/tools/<id>.json    # per-tool input/options, written on change (debounced)
```

Gitignored, atomic writes (temp file + rename), never outside the repo. Deleting
`state/` resets the app. No telemetry, no network, ever — the reason DevToys
exists applies here too.

---

## 11. Layout

```text
tinytools/
├── README.md                 # what it is, build, run, tool list, troubleshooting
├── AGENTS.md                 # lualab conventions + toolbox rules
├── PLAN.md
├── NOTICE                    # MIT: LuaJIT-ImGui, Dear ImGui, cimgui, GLFW, LuaJIT-GLFW/GL
├── Makefile                  # submodules | libs | test | smoke | run | clean
├── .gitignore                # + /build/  /state/
├── lib/
│   ├── imguikit.lua          # env, bootstrap, DPI, theme, shutdown
│   ├── shell.lua             # sidebar, search, groups, favorites, suggestion chip
│   ├── detect.lua            # clipboard content detectors (pure)
│   ├── timer.lua             # QPC / clock_gettime monotonic clock
│   ├── store.lua             # settings + per-tool state, atomic JSON files
│   ├── workloads.lua         # benchmark workloads (used by lua.jitbench only)
│   └── tools/
│       ├── init.lua          # metadata registry
│       └── <id>.lua          # draw / run / selftest per tool
├── apps/
│   └── toolbox.lua           # CLI dispatch + GUI entry
├── tests/
│   ├── harness.lua
│   ├── test_registry.lua     # metadata ↔ file agreement, ids unique/groups sane
│   ├── test_tools.lua        # iterates registry, calls run + selftest for each
│   ├── test_detect.lua
│   └── test_cli.lua          # --list, --run, unknown id, exit codes, no deps
├── scripts/
│   └── check_env.lua
└── submodules/               # 3 submodules, recursive
```

---

## 12. Milestones

| # | Deliverable | Acceptance |
|---|---|---|
| **M1** | registry, `lib/timer.lua`, `lib/detect.lua`, 5 headless tools (`data.json`, `data.base64`, `num.base`, `hash.crc32`, `gen.uuid`), CLI `--list`/`--run`/`--selftest`, `tests/*`, Makefile `test` | `make test` green with `submodules/` empty and no display; registry/file drift caught; unknown id exits 1; `luajit -bl` clean of unexercised globals |
| **M2** | submodules, `make libs`, `imguikit`, `apps/toolbox.lua` shell, 3 tools wired to GUI | `--smoke 300` twice exits 0; GUI path with deinit'd submodules exits 3 with `make submodules libs` text; `git status` free of `*.dll`; first frame renders before any tool module is loaded (verified by a startup log) |
| **M3** | `text.case`, `text.diff`, `text.pattern`, `text.escape`, `data.jwt`, `lua.ffi_layout`, `lua.jitbench`; search, favorites, recents, smart paste, coroutine jobs | search finds by keyword and description; favorites survive restart; JIT toggle changes the ratio mid-run; Cancel stops a long job with no orphan process; every tool answers `--run` |
| **M4** | `lua.bytecode`, `img.grid`, export, settings UI, `NOTICE`, `lualab` README cross-link, CI smoke job | image grid needs textures and lands here; exported JSON matches `--run --json`; window closes via titlebar with clean shutdown |

CI: `make test` always-on (windows + ubuntu, no GL); `make smoke` under
`xvfb-run` + Mesa from M2, non-blocking.

---

## 13. Risks

| Risk | Mitigation |
|---|---|
| Toolbox sprawl: N tools, each half-finished | Admission rule (§1) + every tool must pass `selftest`; no tool without a headless `run` |
| Slow tool freezes the UI | Coroutine job pattern is the default for anything over one frame; bench tool uses it first |
| Startup time grows with tool count | Metadata-only registry, lazy `require`, budget assertion in the startup log |
| No PCRE in LuaJIT | `text.pattern` is honest: it tests Lua patterns and says so in the header |
| No crypto library | CRC32/Adler32 via FFI in v1; SHA-256 either deferred or FFI'd to an OS provider, never sold as fast |
| Upstream `cmake_minimum_required(VERSION 2.8)` rejected by CMake ≥ 4 | Pin CMake 3.x; `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` if CMake 4 is in use |
| First recursive init pulls 6 cimgui-family repos + imgui + GLFW | Document size; deinit supported for headless work; never vendor generated `cdefs.lua` |
| imgui/cimgui drift breaks hand-written binding parts | Submodule commit is the pin; `--check` prints SHAs and versions |
| GLFW < 3.3 breaks `ImGui_ImplGlfw_GetContentScaleForMonitor` | Build GLFW 3.4 from the nested submodule, not the system one |
| HiDPI double scaling | Scaling lives only in `imguikit` |
| Clipboard-only smart paste silently switches tools | Auto-switch only on a single high-confidence match with empty input; otherwise chip |
| `state/` corruption on crash | Atomic temp+rename writes; malformed JSON falls back to defaults with a visible warning |

---

## 14. Do not

- Commit `build/`, `state/`, `*.dll`, `*.so`, or an unpacked upstream archive.
- Add these tests to any `lualab` runner, or add a `LuaJIT` submodule here.
- Put tool logic inside `draw`; `draw` renders state, `run` computes it.
- Claim absolute performance numbers. The only assertion stays the regression
  floor: FFI variants `>= 2x` their Lua variant.
- Add a tool that only wraps a shell one-liner.
