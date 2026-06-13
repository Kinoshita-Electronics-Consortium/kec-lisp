# Changelog

## 0.1.0 — 2026-06-13

First standalone release of KEC Lisp (KN-86 Standard), extracted greenfield
from the KN-86 emulator per ADR-0037.

### Added
- **Fe Kernel** (Layer 0) vendored from `rxi/fe` 1.0, frozen and unmodified.
- **KEC Core** (Layer 1) — the prelude authored in KEC Lisp, conforming to
  standard §4: `def`, `list`, `cmp`, `pred`, `ctrl`, `hof`, `str`. All
  linear traversals are iterative to respect the kernel's 256-root GC stack.
- **Portable host stdlib** (Layer 2) — `type-of` (standard §4.7), math,
  string leaves, I/O, sys, and `try`, gated by `KEC_PROFILE_FULL` /
  `KEC_PROFILE_SANDBOX` (capability-by-binding-set).
- **Embedding API** (`kec.h`) — `kec_open`, `kec_eval_*`, `kec_bind_fe`, error
  recovery via a guard stack (no `exit()` on script error).
- **`kec` CLI** — `repl`, `run`, `eval`, `build` (inline + parse-check +
  bundle), `test`.
- **Test harness** — xUnit in KEC Lisp (`deftest`/`check`/`check-err`) plus a
  conformance suite wired into CTest.

### Known deviations from the standard (surfaced for amendment)
- **Numeric equality is `==` / `/=`, not `=`** (standard §4.1). The kernel's
  `=` is assignment and is frozen; it cannot double as equality. Recommend the
  standard adopt `==`.
- **`(type-of x)` ships here** as a host primitive (ADR-0037 follow-on #2 was
  "add to the device Stdlib"); it is portable, so the standalone repo carries
  it and Core's tag predicates are conformant out of the box.

### Notes
- The Fe Kernel is a tree-walking interpreter; `kec build` is an ahead-of-time
  link/validate/bundle step, not a bytecode compiler.
