LUAJIT ?= luajit
OUT := $(CURDIR)/build/out
GLUE := -static-libgcc -static-libstdc++

.PHONY: test selftest list run smoke libs dist submodules help

help:
	@echo "make test       run the headless test suite"
	@echo "make selftest   run every tool's selftest"
	@echo "make list       list tools"
	@echo "make run        start the GUI"
	@echo "make smoke      render 300 frames in a hidden window and exit"
	@echo "make libs       build GLFW + cimgui into build/out"
	@echo "make dist       assemble self-contained dist/tinytools (needs make libs)"
	@echo "make submodules fetch the three binding submodules"

test:
	@$(LUAJIT) tests/run.lua

selftest:
	@$(LUAJIT) apps/toolbox.lua --selftest

list:
	@$(LUAJIT) apps/toolbox.lua --list

run:
	@$(LUAJIT) apps/toolbox.lua

smoke:
	@$(LUAJIT) apps/toolbox.lua --smoke 300

# Builds GLFW and the cimgui binding into build/out (no system install).
libs:
	@cmake -S submodules/LuaJIT-GLFW/GLFW -B build/glfw -G Ninja \
	  -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_INSTALL_PREFIX="$(OUT)" \
	  -DBUILD_SHARED_LIBS=ON \
	  -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF -DGLFW_BUILD_DOCS=OFF
	@cmake --build build/glfw --target install
	@cmake -S submodules/LuaJIT-ImGui -B build/imgui -G Ninja \
	  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
	  -DGLFW_PATH="$(OUT)" \
	  -DIMPL_GLFW=ON -DIMPL_OPENGL3=ON -DIMPL_OPENGL2=OFF \
	  -DIMPL_SDL=OFF -DIMPL_SDL3=OFF -DIMPL_EXTRAS=ON \
	  -DLUAJIT_BIN="$(OUT)" \
	  -DCMAKE_SHARED_LINKER_FLAGS="$(GLUE)"
	@cmake --build build/imgui --target install
	@$(LUAJIT) scripts/install_glue.lua "$(OUT)"

# Self-contained bundle: LuaJIT + sources + binding DLLs + launcher.
dist:
	@$(LUAJIT) scripts/package.lua

submodules:
	@git submodule update --init --recursive
