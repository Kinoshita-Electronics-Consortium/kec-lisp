# KEC Lisp — convenience Makefile.
#
# This is a thin wrapper over CMake (the real build system): `make` drives
# `cmake` under the hood so the common flow is the familiar one —
#
#     git clone … && cd kec-lisp
#     make                 # configure + build  -> build/kec
#     make install         # build + install    -> ~/.local/bin/kec
#     make test            # build + run the ctest suite
#     make clean           # remove the build dir
#
# Override any of these on the command line:
#
#     make install PREFIX=/usr/local   # install elsewhere (kec lands in <prefix>/bin)
#     make BUILD_TYPE=Debug            # debug build
#     make BUILD_DIR=out               # build in ./out instead of ./build
#     make JOBS=4                      # cap parallel compile jobs (default: all cores)
#
# CMake remains the source of truth (CI and the KN-86 firmware both build the
# sources directly); this Makefile only spares you from typing the `cmake`
# incantations by hand. There is no hand-written compile rule here.

BUILD_DIR  ?= build
BUILD_TYPE ?= Release
CMAKE      ?= cmake

# Parallelism forwarded to `cmake --build`. `-j` with no number uses all cores
# (matches CI); set JOBS=N to cap it.
ifdef JOBS
JOBS_ARG := -j $(JOBS)
else
JOBS_ARG := -j
endif

# PREFIX is optional. When set, it's forwarded at INSTALL time (via
# `cmake --install --prefix`), which overrides the configured prefix regardless
# of how the build dir was configured — so `make install PREFIX=…` always works,
# even on an already-configured tree. When unset, the prefix defaults to
# ~/.local (see CMakeLists.txt).
ifdef PREFIX
INSTALL_PREFIX_ARG := --prefix $(PREFIX)
endif

.PHONY: all build configure install test clean repl help
.DEFAULT_GOAL := all

all: build

# Configure once: the cache file is the stamp. `cmake --build` below
# auto-reconfigures if CMakeLists.txt changes, so this only runs on a fresh tree.
$(BUILD_DIR)/CMakeCache.txt:
	$(CMAKE) -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=$(BUILD_TYPE)

configure: $(BUILD_DIR)/CMakeCache.txt

build: configure
	$(CMAKE) --build $(BUILD_DIR) $(JOBS_ARG)

# `make install` is the one-step build + install: it depends on `build`, then
# installs. Honors PREFIX (see above); default lands in ~/.local/bin.
install: build
	$(CMAKE) --install $(BUILD_DIR) $(INSTALL_PREFIX_ARG)

test: build
	ctest --test-dir $(BUILD_DIR) --output-on-failure

repl: build
	$(BUILD_DIR)/kec

clean:
	rm -rf $(BUILD_DIR)

help:
	@echo "targets:"
	@echo "  make            configure + build            -> $(BUILD_DIR)/kec"
	@echo "  make install    build + install              -> <prefix>/bin/kec (default ~/.local)"
	@echo "  make test       build + run the ctest suite"
	@echo "  make repl       build + start the REPL"
	@echo "  make clean      remove $(BUILD_DIR)/"
	@echo ""
	@echo "vars: PREFIX=<dir>  BUILD_TYPE=Debug|Release  BUILD_DIR=<dir>  JOBS=<n>"
