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

# Core modules — order is the dependency order (def first, str last).
set(CORE_SRCS
  ${CMAKE_SOURCE_DIR}/core/00-def.lsp
  ${CMAKE_SOURCE_DIR}/core/10-list.lsp
  ${CMAKE_SOURCE_DIR}/core/20-cmp.lsp
  ${CMAKE_SOURCE_DIR}/core/30-pred.lsp
  ${CMAKE_SOURCE_DIR}/core/40-ctrl.lsp
  ${CMAKE_SOURCE_DIR}/core/50-hof.lsp
  ${CMAKE_SOURCE_DIR}/core/60-str.lsp)

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

add_custom_target(kec_generated
  DEPENDS ${GEN_DIR}/kec_core_embed.h ${GEN_DIR}/kec_harness_embed.h)

# ---------------------------------------------------------------------------
# Library + CLI.
# ---------------------------------------------------------------------------
add_library(kec_core STATIC
  kernel/fe.c
  host/host.c
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
set(TEST_FILES
  tests/kernel/kernel.lsp
  tests/core/def.lsp
  tests/core/list.lsp
  tests/core/cmp.lsp
  tests/core/pred.lsp
  tests/core/ctrl.lsp
  tests/core/hof.lsp
  tests/core/str.lsp)
foreach(t ${TEST_FILES})
  add_test(NAME ${t} COMMAND kec test ${CMAKE_SOURCE_DIR}/${t})
endforeach()
