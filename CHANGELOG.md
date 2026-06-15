# Changelog

## Unreleased

### Changed
- **`defn` / `define` / `defmacro` now return the value they define** instead of
  `nil` (GWP-534). `set` returns `nil`, so the macros previously echoed `nil`;
  they now hand back the function, macro, or value, so definitions chain and the
  REPL shows something useful. The underlying `set` keeps its exact scoping.
- **`try` now surfaces the error message** (GWP-532). On failure it returns the
  pair `(:error . "message")` instead of a bare `:error` symbol — `car` is the
  `:error` symbol (failure stays recognizable) and `cdr` is the captured error
  string. Success still returns the thunk's value. The test harness's `check-err`
  is updated to key off the `:error` car, so the suite stays green.

### Fixed
- **Buffer overflow in string escape handler at EOF** (upstream rxi/fe issue #34).
  A backslash at the very end of input (e.g. `(read-string "\"\\")` or a
  truncated cart file) caused `strchr("nrt", '\0')` to match the NUL terminator
  of the lookup string, then `strchr("n\nr\rt\t", '\0')[1]` to read one byte past
  the end of that global string. Added an explicit `fe_error("unclosed string")`
  check after the inner `chr = fn()` call, consistent with the guard already
  present at the top of the string-reading loop. Covered by a new
  `kernel/string-escape-eof` test.
- **`fe_write()` no longer crashes or loops infinitely on circular structures**
  (upstream rxi/fe PR #22). A user at the REPL can construct a circular list
  with `setcar`/`setcdr`; the old code followed the cycle forever, causing a
  stack overflow or hang. The fix borrows `GCMARKBIT` during traversal to detect
  cycles and prints `...` in their place, then immediately clears the marks.
  Covered by the `kernel/circular-print` test, which also pins mark restoration
  (a leaked mark bit corrupts the pair's car pointer, so post-print walkability
  is a direct check).
- **Comments terminated by `\r` now parse correctly** (upstream rxi/fe PR #25
  partial). Source files with Windows-style `\r\n` line endings had their `\r`
  swallowed into the next token after a `;` comment, corrupting the parse. The
  comment-skip loop now stops on either `\n` or `\r`.
- **GC save in `fe_open()` now covers the `t` symbol** (upstream rxi/fe PR #25
  partial). `fe_savegc` was called after `fe_symbol(ctx, "t")`, so a GC cycle
  triggered by that allocation could theoretically collect the freshly created
  `t` object before it was stored in `ctx->t`. The save now precedes the
  allocation.
- **String host primitives no longer truncate at ~4 KB** (GWP-528).
  `string-length`, `string-ref`, `substring`, `string-append`/`str`, and `repr`
  copied through a fixed 4 KB C buffer, so any string past ~4095 bytes was
  silently clipped — even though `read-file` reads larger files. They now stream
  the value through `fe_write` to measure its real length, then size a heap
  buffer to fit. Core `split`/`join` (built on these) are fixed as a consequence.

### Changed
- **`kec build` now inlines `(load "...")` structurally through the Lisp reader**
  instead of scanning source lines as strings. Only top-level literal load forms
  are bundled; nested or quoted load forms remain ordinary program code. This
  makes multiline loads work and prevents function-body loads from being
  accidentally treated as build-time dependencies.
- **`kec test` with no file arguments now runs the whole conformance suite**
  baked into the binary, instead of reporting `0 checks, 0 failed`. The suite
  is embedded the same way Core and the harness are, so `kec test` works from
  any directory with no repo on disk. Naming explicit files still runs just
  those. CTest registers each file individually (granular failures) from the
  same source list the binary embeds, so the two can't drift.

### Added
- **`equal?` and alist helpers** — structural list/pair equality plus
  record-like helpers over association lists: `get`, `put`, `has?`, `keys`,
  `values`, and `merge`. `=` / `is` keep their pair-identity semantics;
  `equal?` is the explicit contents comparator.
- **Quasiquote syntax** — backquote, comma, and comma-at now read as
  `quasiquote`, `unquote`, and `unquote-splicing`, with Core expansion into
  ordinary `quote` / `cons` / `append` forms. Macro authors no longer have to
  hand-build every expansion with nested `list` calls.
- **`provide` / `provided?` / `require`** — runtime feature markers and
  load-once file requiring. `provide` and `provided?` are available in every
  profile; `require` is **FULL profile only** because it evaluates files.
- **`sort`** — a Core function: `(sort xs less?)` returns a new list ordered by
  the binary predicate, leaving the input unmutated (GWP-532). Stable, iterative,
  bottom-up merge sort — GC-stack-safe on a 1000+ element list. Lives in the new
  `core/70-sort.lsp` module.
- **`apply` / `read-string`** — language-level, available in every profile
  (GWP-531). `(apply f arglist)` calls `f` with the elements of `arglist`; it's
  built by synthesizing a quoted call form and `fe_eval`-ing it, so the frozen
  kernel is untouched. `(read-string s)` parses the first s-expression of `s`
  with the existing reader and returns it **unevaluated** — a reader, not `eval`,
  preserving the "no eval from Lisp" stance.
- **`file-exists?` / `list-dir` / `getenv`** — filesystem and environment
  introspection (GWP-530). `(file-exists? path)` → truthy/nil via `stat`;
  `(list-dir path)` → entry names (excluding `.`/`..`) via `readdir`, raising a
  catchable error on an unopenable directory; `(getenv name)` → string or nil.
  **FULL profile only**, gated and asserted like the rest of the file/sys set.
- **`write-file` / `append-file`** — file output, the write-side counterpart to
  `read-file` (GWP-529). `(write-file path value)` creates/overwrites;
  `(append-file path value)` appends. The value is stringified the writer's way
  (like `princ`/`str`), writes past 4 KB are byte-exact, and I/O failures raise
  a catchable error rather than calling `exit`. **FULL profile only** — gated
  exactly like `read-file`, asserted by the C profile-gating test.
- **`kec_open_with_arena(buf, size, profile)`** — open an interpreter on a
  caller-provided arena with no malloc of the arena, for embedders that avoid
  the heap (the KN-86 device). Same lifecycle as `kec_open`; returns NULL
  cleanly if the buffer is too small to load Core, and never frees a
  caller-owned buffer. `kec_open` now delegates to it. (GWP-502)

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
- `fe_write()` is safe on circular structures (upstream PR #22).
- Comment parser terminates on `\r` as well as `\n` (upstream PR #25).
- `fe_savegc` in `fe_open()` precedes the `t` symbol allocation (upstream PR #25).
- String escape handler guards against EOF after backslash (upstream issue #34).

### Notes
- `kec build` isn't a compiler — Fe is a tree-walking interpreter. It inlines
  top-level literal `(load "...")` forms, checks the program parses, and writes
  one self-contained `.kec` file.
