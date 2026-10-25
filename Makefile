LUAJIT ?= luajit
PYTHON ?= python
OUT := $(CURDIR)/build/out
GLUE := -static-libgcc -static-libstdc++
CMAKE_GENERATOR ?= $(shell which ninja >/dev/null 2>&1 && echo Ninja || echo "Unix Makefiles")

# Detect OS for platform-specific RPATH and flags
UNAME_S := $(shell uname -s 2>/dev/null || echo Windows)
ifeq ($(UNAME_S),Darwin)
  CMAKE_RPATH ?= @loader_path
else
  CMAKE_RPATH ?= \$$ORIGIN
endif

.PHONY: test test-gui test-exe selftest list run smoke libs dist exe bundle submodules check-deps clean help

help:
	@echo "make test       run the headless test suite"
	@echo "make test-gui   check GUI interactions in a hidden window"
	@echo "make test-exe   check the built Windows single EXE"
	@echo "make selftest   run every tool's selftest"
	@echo "make list       list tools"
	@echo "make run        start the GUI"
	@echo "make smoke      render 300 frames in a hidden window and exit"
	@echo "make libs       build GLFW + cimgui into build/out"
	@echo "make bundle     combine all app Lua files into tinytools_bundle.lua"
	@echo "make dist       assemble self-contained dist/tinytools (needs make libs)"
	@echo "make exe        build dist/tinytools.exe on Windows (needs make libs)"
	@echo "make submodules fetch the three binding submodules"
	@echo "make clean      remove build and dist outputs"

test:
	@$(LUAJIT) tests/run.lua

test-gui:
	@$(LUAJIT) tests/gui_smoke.lua

test-exe:
	@$(PYTHON) -m unittest discover -s tests -p test_package_exe.py -v

selftest:
	@$(LUAJIT) apps/toolbox.lua --selftest

list:
	@$(LUAJIT) apps/toolbox.lua --list

run:
	@$(LUAJIT) apps/toolbox.lua

smoke:
	@$(LUAJIT) apps/toolbox.lua --smoke 300

# Check required tools before building
check-deps:
	@missing=""; \
	command -v cmake >/dev/null 2>&1 || missing="$$missing cmake"; \
	command -v $(LUAJIT) >/dev/null 2>&1 || missing="$$missing $(LUAJIT)"; \
	command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || missing="$$missing C-compiler(gcc/clang)"; \
	if [ -n "$$missing" ]; then \
	  echo "Error: missing required build tools:$$missing"; \
	  echo ""; \
	  if command -v pacman >/dev/null 2>&1; then \
	    echo "Install with: sudo pacman -S cmake ninja gcc luajit"; \
	  elif command -v apt-get >/dev/null 2>&1; then \
	    echo "Install with: sudo apt update && sudo apt install -y cmake ninja-build build-essential luajit"; \
	  elif command -v dnf >/dev/null 2>&1; then \
	    echo "Install with: sudo dnf install -y cmake ninja-build gcc-c++ luajit"; \
	  elif command -v brew >/dev/null 2>&1; then \
	    echo "Install with: brew install cmake ninja luajit"; \
	  fi; \
	  exit 1; \
	fi

# Builds GLFW and the cimgui binding into build/out (no system install).
libs: check-deps
	@if [ ! -f "submodules/LuaJIT-GLFW/GLFW/CMakeLists.txt" ]; then \
	  echo "Fetching submodules..."; \
	  git submodule update --init --recursive; \
	fi
	@cmake -S submodules/LuaJIT-GLFW/GLFW -B build/glfw -G "$(CMAKE_GENERATOR)" \
	  -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_INSTALL_PREFIX="$(OUT)" \
	  -DBUILD_SHARED_LIBS=ON \
	  -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF -DGLFW_BUILD_DOCS=OFF
	@cmake --build build/glfw --parallel --target install
	@cmake -S submodules/LuaJIT-ImGui -B build/imgui -G "$(CMAKE_GENERATOR)" \
	  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
	  -DGLFW_PATH="$(OUT)" \
	  -DIMPL_GLFW=ON -DIMPL_OPENGL3=ON -DIMPL_OPENGL2=OFF \
	  -DIMPL_SDL=OFF -DIMPL_SDL3=OFF -DIMPL_EXTRAS=ON \
	  -DLUAJIT_BIN="$(OUT)" \
	  -DCMAKE_INSTALL_RPATH="$(CMAKE_RPATH)" \
	  -DCMAKE_SHARED_LINKER_FLAGS="$(GLUE)"
	@cmake --build build/imgui --parallel --target install
	@$(LUAJIT) scripts/install_glue.lua "$(OUT)"

clean:
	@rm -rf build dist tinytools_bundle.lua

# Combines all application Lua files into a single standalone Lua script.
bundle:
	@$(LUAJIT) scripts/bundle.lua

# Self-contained bundle: LuaJIT + sources + binding DLLs + launcher.
dist:
	@$(LUAJIT) scripts/package.lua

# Single Windows EXE: native launcher + compressed folder bundle.
exe:
	@$(PYTHON) scripts/package_exe.py

submodules:
	@git submodule update --init --recursive
