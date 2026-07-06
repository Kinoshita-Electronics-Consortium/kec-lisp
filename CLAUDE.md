# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

KEC Lisp is the standalone scripting language for the KN-86 handheld terminal —
just the language: the interpreter, a Lisp-authored standard library, a `kec`
CLI, and tests. It runs on a normal computer with no KN-86 hardware. The device
primitives (graphics, sound, save state, missions, CIPHER voice) are **not**
here — the firmware vendors this repo as a library and registers those on top
through the same FFI seam. See `docs/boundary.md` for the in/out boundary.

This is the standalone language; it is vendored into the **nOSh runtime**. The
wider KN-86 multi-repo ecosystem map lives in the `jschairb/kn86-deckline`
monorepo CLAUDE.md ("Repository Topology") and `kn86-docs` ADR-0039.

## Commands

```sh
cmake -S . -B build              # configure (Release by default)
cmake --build build              # build → build/kec
ctest --test-dir build --output-on-failure   # run the full suite
cmake --install build            # install kec → ~/.local/bin (no sudo; prefix defaults to ~/.local)

./build/kec                      # REPL
./build/kec run FILE [args...]   # run a script; args reach Lisp (args)
./build/kec eval "EXPR"          # evaluate one expression, print result
./build/kec build FILE [-o OUT]  # inline top-level loads, parse-check, write one .kec
./build/kec test [FILE...]       # run the harness over FILE(s), or the whole embedded suite if none; exit 0 = all green
```

Run a single conformance file directly (faster than ctest for one file):

```sh
./build/kec test tests/core/list.lsp
```

`kec build` is **not** a compiler — Fe is a tree-walking interpreter. It inlines
top-level literal `(load "...")` forms, checks the whole program parses, and
writes a self-contained `.kec` file. CI (`.github/workflows/ci.yml`) builds +
tests on ubuntu and macos and smoke-runs an `eval` and `fizzbuzz`.

## Docs site (`docs/` → `website/`)

The Starlight site in `website/` loads its content collection straight from the
top-level `docs/` tree (`website/src/content.config.ts`: `glob({ base: '../docs' })`,
`schema: docsSchema()`). **Every `.md`/`.mdx` under `docs/` is a Starlight page and
MUST start with YAML frontmatter carrying at least a `title:`** (add a `description:`
too, by convention). Do **not** open with an in-body `# H1` — Starlight renders the
title from frontmatter, so an H1 just duplicates it. Skeleton:

```md
---
title: My Page
description: One-line summary.
---

Body starts here — no H1.
```

**This is a CI blind spot.** `ctest` and the `CI` workflow build/test the language
only — they never touch `website/`. A `docs/` file with missing or malformed
frontmatter therefore passes `CI` green and only breaks the separate **`Docs`**
workflow (`.github/workflows/docs.yml`), which builds + deploys the site and runs
**only on push to `main`** — so the failure surfaces *after* merge, not on the PR.
Before merging any `docs/` change, validate the site build locally:

```sh
cd website && npm install && npm run build   # fails loudly on bad/missing frontmatter
```

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
(`CORE_SRCS`): `00-def → 10-list → 20-cmp → 25-alist → 26-plist → 30-pred →
35-error → 40-ctrl → 45-quasiquote → 50-hof → 60-str → 70-sort`. A new Core module must
be slotted into that list at the right position. The list/sequence functions
are written **iteratively** on purpose so a library call won't exhaust the GC
stack on a long list.

### Memory model

Fe objects are arena-allocated with no GC heap growth — one `kec_State` owns one
Fe context + one arena. Vector/hash backing is external and uses a per-context
allocator (`kec_set_container_allocator_for`), with malloc/free as the desktop
default. `kec_open(bytes, profile)` mallocs the Fe arena; desktop uses
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
- **Symbols track binding presence separately from value**, so bound-to-`nil`
  differs from unbound (`fe_bound`). Fe also has four tagged userdata entries and
  composable typed-`FE_TPTR` lifecycle registration (plus `fe_set_ptr` for
  leak-free two-phase foreign construction); legacy raw pointer handlers
  remain available.

## Language gotchas

- `nil` is the only false value **and** the empty list. Everything else
  (including `0` and `""`) is true. No boolean type; `:keyword`s are ordinary
  symbols.
- Numbers are single-precision `float` — integers are exact only within ±2²⁴.
- `(is a b)` / `=` compare numbers by value and strings structurally, but **pairs
  by identity** — `=` on two lists checks identity, not contents.
- Quasiquote is available: `` `x `` / `,x` / `,@x` read as `quasiquote`,
  `unquote`, and `unquote-splicing`. Macros (`mac`) can still build expansions
  manually with `list`/`cons`/`append` when useful.
- **Referencing a never-bound symbol evaluates to `nil`, not an error** — there
  is no "unbound variable" signal on read, so a typo'd name silently reads as
  `nil` instead of failing loudly. Use `(bound? 'name)` to check. Calling a
  never-bound symbol (as a list operator) still errors, since `nil` isn't
  callable.

Full reference: `docs/language.md`. Test harness API (`deftest` / `check` /
`check-err`) is defined in `tests/harness.lsp`.

## Code style (C)

C11, 4-space indent, ~100 char lines, `/* ... */` comments (not `//`). When
adding a C source file, wire it into `CMakeLists.txt`. When adding a Core module
or a test file, add it to `CORE_SRCS` / `TEST_FILES` respectively.
