cmake_minimum_required(VERSION 3.16)
project(kec_lisp C)

#
# KEC Lisp (KN-86 Standard) — standalone language + host runtime.
#
#   Layer 0  kernel/   vendored Fe VM (frozen rxi/fe 1.0)
#   Layer 1  core/     KEC Core prelude (KEC Lisp source, embedded at build)
#   Layer 2  host/     portable host stdlib (type-of, math, string, I/O, sys)
#            runtime/  embedding API + error recovery + Core injection
#            cli/      the `kec` driver (repl / run / build / test / eval)
#

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
add_compile_options(-Wall -Wextra)

set(KEC_VERSION "0.1.0")

# ---------------------------------------------------------------------------
# Codegen: bake KEC Core (and the test harness) into C string literals so the
# `kec` binary is a single relocatable artifact with no runtime file lookup.
# ---------------------------------------------------------------------------
add_executable(mkembed tools/mkembed.c)

set(GEN_DIR ${CMAKE_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GEN_DIR})

# Core modules — order is the dependency order.
set(CORE_SRCS
  ${CMAKE_SOURCE_DIR}/core/00-def.lsp
  ${CMAKE_SOURCE_DIR}/core/10-list.lsp
  ${CMAKE_SOURCE_DIR}/core/20-cmp.lsp
  ${CMAKE_SOURCE_DIR}/core/25-alist.lsp
  ${CMAKE_SOURCE_DIR}/core/26-plist.lsp
  ${CMAKE_SOURCE_DIR}/core/30-pred.lsp
  ${CMAKE_SOURCE_DIR}/core/35-error.lsp
  ${CMAKE_SOURCE_DIR}/core/36-recover.lsp
  ${CMAKE_SOURCE_DIR}/core/40-ctrl.lsp
  ${CMAKE_SOURCE_DIR}/core/45-quasiquote.lsp
  ${CMAKE_SOURCE_DIR}/core/50-hof.lsp
  ${CMAKE_SOURCE_DIR}/core/52-container.lsp
  ${CMAKE_SOURCE_DIR}/core/55-util.lsp
  ${CMAKE_SOURCE_DIR}/core/60-str.lsp
  ${CMAKE_SOURCE_DIR}/core/65-strtool.lsp
  ${CMAKE_SOURCE_DIR}/core/70-sort.lsp)

add_custom_command(
  OUTPUT ${GEN_DIR}/kec_core_embed.h
  COMMAND mkembed ${GEN_DIR}/kec_core_embed.h KEC_CORE_SRC ${CORE_SRCS}
  DEPENDS mkembed ${CORE_SRCS}
  COMMENT "Embedding KEC Core")

add_custom_command(
  OUTPUT ${GEN_DIR}/kec_harness_embed.h
  COMMAND mkembed ${GEN_DIR}/kec_harness_embed.h KEC_HARNESS_SRC
          ${CMAKE_SOURCE_DIR}/tests/harness.lsp
  DEPENDS mkembed ${CMAKE_SOURCE_DIR}/tests/harness.lsp
  COMMENT "Embedding test harness")

# Conformance suite — single source of truth, reused below by the embedded
# `kec test` default (baked into the binary) and the per-file ctest loop.
# Order is logical: kernel first, then Core in dependency order.
set(SUITE_SRCS
  ${CMAKE_SOURCE_DIR}/tests/kernel/kernel.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/def.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/list.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/cmp.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/alist.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/plist.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/pred.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/error.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/recover.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/ctrl.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/quasiquote.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/macroexpand.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/macro-robustness.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/hof.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/vector.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/hash.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/container-gc.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/util.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/str.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/strtool.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/bitwise.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/rng.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/bigstr.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/fileio.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/fsenv.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/require.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/applyread.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/eval.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/introspect.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/sort.lsp
  ${CMAKE_SOURCE_DIR}/tests/core/trymsg.lsp)

add_custom_command(
  OUTPUT ${GEN_DIR}/kec_suite_embed.h
  COMMAND mkembed ${GEN_DIR}/kec_suite_embed.h KEC_SUITE_SRC ${SUITE_SRCS}
  DEPENDS mkembed ${SUITE_SRCS}
  COMMENT "Embedding conformance suite")

# Editor/REPL tier (ADR-0002) — the knEmacs/REPL host-agnostic modules, embedded
# so `kec nemacs` is self-contained. Order is dependency order; loaded on demand
# (NOT part of Core), so it stays out of the minimal device prelude.
set(EDITOR_SRCS
  ${CMAKE_SOURCE_DIR}/editor/10-zipper.lsp
  ${CMAKE_SOURCE_DIR}/editor/20-undo.lsp
  ${CMAKE_SOURCE_DIR}/editor/30-buffer.lsp
  ${CMAKE_SOURCE_DIR}/editor/40-view.lsp
  ${CMAKE_SOURCE_DIR}/editor/50-keymap.lsp
  ${CMAKE_SOURCE_DIR}/editor/60-persist.lsp
  ${CMAKE_SOURCE_DIR}/editor/70-lifecycle.lsp
  ${CMAKE_SOURCE_DIR}/editor/80-ranker.lsp
  ${CMAKE_SOURCE_DIR}/editor/90-repl.lsp
  ${CMAKE_SOURCE_DIR}/editor/95-host.lsp)

add_custom_command(
  OUTPUT ${GEN_DIR}/kec_editor_embed.h
  COMMAND mkembed ${GEN_DIR}/kec_editor_embed.h KEC_EDITOR_SRC ${EDITOR_SRCS}
  DEPENDS mkembed ${EDITOR_SRCS}
  COMMENT "Embedding KEC editor/REPL tier")

add_custom_target(kec_generated
  DEPENDS ${GEN_DIR}/kec_core_embed.h ${GEN_DIR}/kec_harness_embed.h
          ${GEN_DIR}/kec_suite_embed.h ${GEN_DIR}/kec_editor_embed.h)

# ---------------------------------------------------------------------------
# Library + CLI.
# ---------------------------------------------------------------------------
add_library(kec_core STATIC
  kernel/fe.c
  host/host.c
  host/containers.c
  runtime/kec.c)
target_include_directories(kec_core PUBLIC
  ${CMAKE_SOURCE_DIR}/kernel
  ${CMAKE_SOURCE_DIR}/host
  ${CMAKE_SOURCE_DIR}/runtime
  ${GEN_DIR})
target_compile_definitions(kec_core PUBLIC KEC_VERSION="${KEC_VERSION}")
# Desktop has memory to spare — raise Fe's recursion ceiling well past the
# 256-root device default so naive recursive user code doesn't hit the wall.
target_compile_definitions(kec_core PRIVATE GCSTACKSIZE=8192)
add_dependencies(kec_core kec_generated)

add_executable(kec cli/main.c)
target_link_libraries(kec kec_core m)

install(TARGETS kec RUNTIME DESTINATION bin)

# ---------------------------------------------------------------------------
# Conformance suite — each file runs under `kec test` (exit code = failures).
# ---------------------------------------------------------------------------
enable_testing()
# One ctest per file (separate processes → granular per-file failures). Uses
# the same SUITE_SRCS the binary embeds, so the two can never drift apart.
foreach(t ${SUITE_SRCS})
  file(RELATIVE_PATH name ${CMAKE_SOURCE_DIR} ${t})
  add_test(NAME ${name} COMMAND kec test ${t})
endforeach()

add_test(NAME tests/examples/black-ice-trace.lsp
  COMMAND kec test ${CMAKE_SOURCE_DIR}/tests/examples/black-ice-trace.lsp)
set_tests_properties(tests/examples/black-ice-trace.lsp PROPERTIES
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})

# Editor tier (ADR-0002) — the knEmacs/REPL host-agnostic modules. Loaded on
# demand (not baked into Core), so the tests `load` editor/*.lsp relative to the
# source dir; run from the repo root.
foreach(t editor/zipper editor/undo editor/buffer editor/view editor/keymap
          editor/persist editor/lifecycle editor/ranker editor/repl editor/host)
  add_test(NAME tests/${t}.lsp
    COMMAND kec test ${CMAKE_SOURCE_DIR}/tests/${t}.lsp)
  set_tests_properties(tests/${t}.lsp PROPERTIES
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
endforeach()

# `kec test` with no arguments runs the whole suite baked into the binary.
# The regex doubles as the assertion: at least one check ran, none failed.
add_test(NAME cli/test-default COMMAND kec test)
set_tests_properties(cli/test-default PROPERTIES
  PASS_REGULAR_EXPRESSION "[1-9][0-9]* checks, 0 failed")

add_test(NAME cli/build-reader
  COMMAND sh ${CMAKE_SOURCE_DIR}/tests/cli/build-reader.sh $<TARGET_FILE:kec>)

# The `kec nemacs` strong REPL end-to-end (loads the embedded editor tier, drives
# the REPL engine over piped input).
add_test(NAME cli/nemacs-smoke
  COMMAND sh ${CMAKE_SOURCE_DIR}/tests/cli/nemacs-smoke.sh $<TARGET_FILE:kec>)

# ---------------------------------------------------------------------------
# C-level embedding tests — the no-malloc arena seam the .lsp suite can't reach.
# ---------------------------------------------------------------------------
add_executable(test_arena tests/c/test_arena.c)
target_link_libraries(test_arena kec_core m)
add_test(NAME c/arena COMMAND test_arena)
