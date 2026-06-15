# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

KEC Lisp is the standalone scripting language for the KN-86 handheld terminal —
just the language: the interpreter, a Lisp-authored standard library, a `kec`
CLI, and tests. It runs on a normal computer with no KN-86 hardware. The device
primitives (graphics, sound, save state, missions, CIPHER voice) are **not**
here — the firmware vendors this repo as a library and registers those on top
through the same FFI seam. See `docs/boundary.md` for the in/out boundary.

## Commands

```sh
cmake -S . -B build              # configure (Release by default)
cmake --build build              # build → build/kec
ctest --test-dir build --output-on-failure   # run the full suite

./build/kec                      # REPL
./build/kec run FILE [args...]   # run a script; args reach Lisp (args)
./build/kec eval "EXPR"          # evaluate one expression, print result
./build/kec build FILE [-o OUT]  # inline (load ...)s, parse-check, write one .kec
./build/kec test [FILE...]       # run the harness over FILE(s), or the whole embedded suite if none; exit code = # failures
```

Run a single conformance file directly (faster than ctest for one file):

```sh
./build/kec test tests/core/list.lsp
```

`kec build` is **not** a compiler — Fe is a tree-walking interpreter. It inlines
`(load ...)`s, checks the whole program parses, and writes a self-contained
`.kec` file. CI (`.github/workflows/ci.yml`) builds + tests on ubuntu and macos
and smoke-runs an `eval` and `fizzbuzz`.

## Architecture

Strict bottom-up layering — each layer only depends on the ones below it:

| Layer | Dir | What |
|---|---|---|
| 0 | `kernel/` | the Fe VM, vendored from `rxi/fe` 1.0 (frozen, lightly patched) |
| 1 | `core/` | the standard library, **written in KEC Lisp** |
| 2 | `host/` | portable C primitives — `type-of`, math, string, I/O, sys |
| — | `runtime/` | embedding API (`kec.h`): open a context, load Core, eval, recover from errors |
| — | `cli/` | the `kec` driver (repl / run / build / test / eval) |

### Core is baked into the binary at build time

`tools/mkembed.c` is compiled to a `mkembed` host tool that converts the `core/*.lsp`
files (and `tests/harness.lsp`) into C string literals (`build/generated/kec_core_embed.h`,
`kec_harness_embed.h`). The `kec` binary is a single relocatable artifact with
no runtime file lookup for the prelude. **Consequence:** editing a `core/*.lsp`
file requires a rebuild for the change to take effect in the shipped binary.

**Prototyping fast path:** set `KEC_CORE_DIR=/abs/path/to/core` and the `kec`
CLI re-loads those `.lsp` files (name order = the `NN-` dependency order) on top
of the embedded Core at startup, so Core edits take effect with no rebuild. It
*layers over* the baked-in prelude — adding/changing definitions works live; a
definition you *delete* lingers from the embedded copy until you rebuild. Dev
convenience only (CLI subcommands repl/run/eval/test); the embedded Core is what
ships and what the firmware vendors.

**`core/` load order is dependency order** and is hardcoded in `CMakeLists.txt`
(`CORE_SRCS`): `00-def → 10-list → 20-cmp → 30-pred → 40-ctrl → 50-hof → 60-str`.
A new Core module must be slotted into that list at the right position. The
list/sequence functions are written **iteratively** on purpose so a library call
won't exhaust the GC stack on a long list.

### Memory model

Fe is arena-allocated with no GC heap churn — one `kec_State` owns one Fe
context + one arena. `kec_open(bytes, profile)` mallocs the arena; desktop uses
16 MB (`ARENA_BYTES` in `cli/main.c`). `kec_open_with_arena(buf, size, profile)`
is the no-malloc entry point for the device: you supply a static/stack buffer,
it's never freed by `kec_close`, and it returns NULL cleanly if the buffer is
too small to load Core. `kec_open` delegates to it. The C-level arena tests
(`tests/c/test_arena.c`, ctest name `c/arena`) cover this seam, which the `.lsp`
suite can't reach.

### Profiles = capability tiers

`kec_Profile` (`host/host.h`) is which primitives a context gets:
`KEC_PROFILE_FULL` adds file/system primitives on top of
`KEC_PROFILE_SANDBOX`. What you bind into a context is what it's allowed to do.

### Extending with C primitives (the FFI seam)

This is how both the CLI and the downstream firmware add functions. Register a
`fe_CFunc` under a Lisp name with `kec_bind_fe(kec_fe(S), "name", fn)` — it's
GC-safe (saves/restores the GC stack around the symbol + cfunc pushes). Portable
primitives live in `host/host.c` (registered in `kec_host_register`); device
primitives stay in the firmware. See `docs/ffi-bridge.md`.

## Kernel changes vs upstream rxi/fe 1.0

The kernel is frozen except for these deliberate deltas (also in CHANGELOG):

- **Assignment is `set`, not `=`.** This frees `=` to mean equality (`==` is an
  alias). This is the single most important thing to remember when reading or
  writing KEC Lisp.
- **Top-level `let` binds globally** instead of being a silent no-op.
- **`GCSTACKSIZE` is compile-time configurable** (default 256 for the device).
  The desktop build raises it to 8192 (`target_compile_definitions` in
  `CMakeLists.txt`) so recursive user code has headroom.

## Language gotchas

- `nil` is the only false value **and** the empty list. Everything else
  (including `0` and `""`) is true. No boolean type; `:keyword`s are ordinary
  symbols.
- Numbers are single-precision `float` — integers are exact only within ±2²⁴.
- `(is a b)` / `=` compare numbers by value and strings structurally, but **pairs
  by identity** — `=` on two lists checks identity, not contents.
- No quasiquote/unquote. Macros (`mac`) build expansions with `list`/`cons`/`append`.

Full reference: `docs/language.md`. Test harness API (`deftest` / `check` /
`check-err`) is defined in `tests/harness.lsp`.

## Code style (C)

C11, 4-space indent, ~100 char lines, `/* ... */` comments (not `//`). When
adding a C source file, wire it into `CMakeLists.txt`. When adding a Core module
or a test file, add it to `CORE_SRCS` / `TEST_FILES` respectively.
