# Changelog

## 0.1.0 — 2026-06-13

First standalone release, split out from the KN-86 emulator.

### Added
- The Fe interpreter (`kernel/`), vendored from `rxi/fe` with a few small
  changes (see *Kernel changes* below).
- The standard library (`core/`), written in KEC Lisp: `def`, `list`, `cmp`,
  `pred`, `ctrl`, `hof`, `str`. The list/sequence functions are iterative so a
  library call won't exhaust the GC stack on a long list.
- C primitives (`host/`): `type-of`, math, string ops, a little I/O, and `try`,
  with two profiles (`KEC_PROFILE_FULL` / `KEC_PROFILE_SANDBOX`).
- The embedding API (`kec.h`): `kec_open`, `kec_eval_*`, `kec_bind_fe`, and
  error recovery so a script error doesn't take down the process.
- The `kec` CLI: `repl`, `run`, `eval`, `build`, `test`.
- A test harness written in KEC Lisp (`deftest` / `check` / `check-err`) and a
  test suite wired into CTest.

### Kernel changes (vs upstream rxi/fe 1.0)
- Assignment is `set`, not `=`. This leaves `=` free to mean equality. `==` is
  an alias.
- Top-level `let` binds globally instead of being a silent no-op — `(let x v)`
  at the REPL or top of a script used to do nothing.
- `GCSTACKSIZE` is compile-time configurable (default 256). The desktop build
  raises it to 8192 so recursive code has headroom; hosts that vendor the
  kernel can keep 256.

### Notes
- `kec build` isn't a compiler — Fe is a tree-walking interpreter. It inlines
  `(load ...)`s, checks the program parses, and writes one self-contained `.kec`
  file.
