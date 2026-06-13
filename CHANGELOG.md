# Changelog

## 0.1.0 — 2026-06-13

First standalone release of KEC Lisp (KN-86 Standard), extracted greenfield
from the KN-86 emulator per ADR-0037.

### Added
- **Fe Kernel** (Layer 0) vendored from `rxi/fe` 1.0, with three small,
  documented KEC changes (see *Kernel changes* below).
- **KEC Core** (Layer 1) — the prelude authored in KEC Lisp, conforming to
  standard §4: `def`, `list`, `cmp`, `pred`, `ctrl`, `hof`, `str`. All
  linear traversals are iterative so a library call never exhausts the GC
  root stack regardless of list length.
- **Portable host stdlib** (Layer 2) — `type-of` (standard §4.7), math,
  string leaves, I/O, sys, and `try`, gated by `KEC_PROFILE_FULL` /
  `KEC_PROFILE_SANDBOX` (capability-by-binding-set).
- **Embedding API** (`kec.h`) — `kec_open`, `kec_eval_*`, `kec_bind_fe`, error
  recovery via a guard stack (no `exit()` on script error).
- **`kec` CLI** — `repl`, `run`, `eval`, `build` (inline + parse-check +
  bundle), `test`.
- **Test harness** — xUnit in KEC Lisp (`deftest`/`check`/`check-err`) plus a
  conformance suite wired into CTest.

### Kernel changes (vs upstream rxi/fe 1.0)
- **Assignment verb `=` → `set`.** This frees `=` for value equality in Core,
  so the implementation conforms to standard §4.1 (`=` is equality) directly
  rather than deviating to `==`. `==` remains as an alias.
- **Top-level `let` binds globally** instead of being a silent no-op — removes
  a footgun where `(let x v)` at the REPL / script top level did nothing.
- **`GCSTACKSIZE` is compile-time configurable** (`#ifndef`, default 256). The
  desktop build raises it to 8192 so naive recursive user code has headroom;
  memory-tight hosts that vendor the kernel keep 256.

### Notes
- `(type-of x)` ships here as a host primitive (ADR-0037 follow-on #2 placed it
  on the device Stdlib; it is portable, so the standalone repo carries it and
  Core's tag predicates are conformant out of the box).
- The Fe Kernel is a tree-walking interpreter; `kec build` is an ahead-of-time
  link/validate/bundle step, not a bytecode compiler.
