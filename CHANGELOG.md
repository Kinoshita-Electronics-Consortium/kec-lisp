# Changelog

## Unreleased

### Added
- **Editor tier — token-prediction ranker** (`editor/80-ranker.lsp`; ADR-0002,
  L5). A static, deterministic top-8 ranker (no ML) shared by REPL completion and
  the nEmacs palette. Legal-form filter by position (function/argument/binding/
  root); scoring = domain-vocabulary +5, local-binding +3, recency 0–10 (decay
  over a ~24-token window), popularity 0–4, semantic-fit +1; alphabetic tiebreak;
  **never shadows a builtin**. Bounded top-8 insertion (no full sort) over
  hash-backed vocabulary / popularity / builtins / recency indexes (the host
  feeds vocabulary via `ranker-index`, SEAM S8). `rank` / `rank-tokens` /
  `ranker-context`. Iterative (device GC stack 256); a latency spike measured
  ~1.7 ms/call desktop. `tests/editor/ranker.lsp` (9 checks).
- **Editor tier — persistence + lifecycle** (`editor/60-persist.lsp`,
  `editor/70-lifecycle.lsp`; ADR-0002, L7/L8). Persistence is the (serialize,
  load) pair only — the host owns the bytes (SEAM S5): `buffer->string`
  (top-level forms as plain Lisp source; empty buffer → `()`), `buffer-serialize`
  (honors a host byte cap; overflow → `0`), `buffer-load` / `buffer-reload!`
  (parse with the reader, replace the root, reset the cursor; symbol identity by
  intern-by-name). A serialize→load round-trip preserves structural shape.
  Lifecycle is the session state machine (`:init` → `:editor`/`:repl` → `:exited`/
  `:shutdown`, plus `set-mode` over the five scopes) that fires enter/exit/
  mode-change **hooks** the host subscribes to (SEAM S6) — the library performs no
  device side effects itself. `tests/editor/{persist,lifecycle}.lsp` (25 checks).
- **Editor tier — keymap engine + mode scopes** (`editor/50-keymap.lsp`; ADR-0002,
  L2/L3). Keymap-as-data: a hash-table mapping abstract command **tokens** (CAR,
  CDR, BACK, …) — never scancodes — to handler entries with three slots
  (`:tap` / `:double-tap` / `:long-press`, non-tap falling back to `:tap`). Pure
  lookup + call, so dispatch is **headlessly evaluable** (runs under `kec test`).
  Surface: `make-keymap`, `define-key`, `keymap-get`/`-set`, `keymap-handler`,
  `keymap-dispatch`, `copy-keymap`; a mode registry (`register-keymap`/
  `keymap-mode`/`keymap-mode-list`/`mode-dispatch`) over the five scopes
  (`:nemacs-nav` / `:nemacs-literal` / `:repl-prompt` / `:repl-history` / `:grab`);
  an optional `*keymap-rebind-hook*`. Ships a default `:nemacs-nav` keymap (the
  ADR-0008 structural grammar robbed from the KN-86 nEmacs screen) bound to the
  buffer verbs. Boundary moves `raise` for the host to render (SEAM S7).
  `tests/editor/keymap.lsp` (23 checks).
- **Editor tier — structural-edit engine** (`editor/10-zipper.lsp`,
  `editor/20-undo.lsp`, `editor/30-buffer.lsp`, `editor/40-view.lsp`; ADR-0002).
  First modules of the host-agnostic editor/REPL tier (knEmacs core),
  `provide`-gated and loaded on demand — not baked into Core.
  - **Zipper** (10): a Huet zipper structural-edit data model — the cursor is an
    immutable location `(focus . crumbs)`, so every edit yields a well-formed
    tree (no half-typed parens) and undo is an O(1) snapshot. Navigation
    (descend/next-sibling/prev-sibling/ascend/descend-to-leaf) + manipulation
    (insert-leaf/delete-node/paste/wrap/splice/transpose) with boundary "invalid
    move" signals; a print+reparse well-formedness check. (Functional zipper over
    in-place was settled by a spike: zipper undo is O(1), in-place is an O(nodes)
    copy per step.)
  - **Undo** (20): a vector-backed O(1) snapshot ring
    (make-undo-ring/undo-push/undo-pop/undo-peek/undo-depth).
  - **Buffer record** (30): wraps the cursor with the rest of L1 — clipboard,
    modified flag, name — and undo-integrated verb wrappers (navigation moves the
    cursor; edits snapshot for undo, thread the clipboard, and mark modified).
  - **View model** (40, SEAM S4): the abstract view a host paints — a
    `(label . children)` tree projection + the cursor node, a modeline string, an
    echo hint, and a `completion-signature` arglist helper. The shapes match the
    KN-86 nEmacs screen's seam so that device screen can drive this Lisp engine.
  `tests/editor/{zipper,undo,buffer,view}.lsp` (105 checks).
- **Containers — vectors and hash tables** (`host/containers.c`,
  `core/52-container.lsp`; ADR-0003). O(1) indexed and keyed structures as
  `FE_TPTR` foreign objects with GC-integrated backing (a `mark`/`gc` handler
  pair keeps contents alive and frees backing on sweep, including at `fe_close`).
  Primitives: `make-vector`, `vector`, `vector-ref`, `vector-set!`,
  `vector-length`, `vector?`; `make-hash-table`, `hash-set!`, `hash-ref`,
  `hash-has?`, `hash-del!`, `hash-count`, `hash-keys`, `hash-table?`. Core
  helpers: `vector->list`, `list->vector`, `vector-fill!`, `vector-copy`,
  `vector-map`, `vector-for-each`, `hash-values`, `hash->alist`, `alist->hash`,
  `hash-for-each`. Hash keys are numbers (by value), symbols (by identity), or
  strings (by content); other key types raise. Backing memory uses a settable
  allocator (`kec_set_container_allocator`) defaulting to malloc/free, so the
  no-malloc device path installs an arena-bump allocator instead — closing
  ADR-0001's deferred container concern. `tests/core/{vector,hash,container-gc}.lsp`.
- **GNU Emacs major mode** (`editors/emacs/kec-lisp-mode.el`) for editing `.lsp`
  KEC Lisp: file detection, font-lock, KEC-aware indentation, completion-at-point
  (standard library + buffer definitions + the live interpreter's `(globals)`),
  Flymake (a precise local paren-balance check plus an optional `kec build`
  parse-check), and an inferior `kec` REPL. 18 ERT tests under
  `editors/emacs/kec-lisp-mode-tests.el`.
- **`eval` — evaluate a data form in the live image** (`FULL` profile only).
  `(eval form)` runs an already-read form and returns its value; with
  `read-string` / `read-all` it gives `eval-defun`, a scratch REPL, and
  config-as-code. It is a privileged editor/REPL-tier capability, deliberately
  **not** bound into `SANDBOX` — the existing "no eval in the sandbox" stance is
  preserved by binding, alongside `load`. Covered by `tests/core/eval.lsp`.
- **`read-all` — parse every top-level form of a string** (host, both profiles).
  The multi-form companion to `read-string`; returns a list of forms in source
  order, nothing evaluated. Length-aware (no 4 KB clip). For `(for-each eval
  (read-all src))` config loading. `tests/core/eval.lsp`.
- **`get-prop` / `put-prop` — symbol property registry** (Core, `26-plist.lsp`).
  Classic Lisp symbol properties in a side registry (Fe symbols have no plist
  slot); named `*-prop` because `get`/`put` already operate on alists. For the
  per-symbol metadata an editor wants — indent rules, docstrings, a `disabled`
  flag. `tests/core/plist.lsp`.
- **`fn-params` — a closure/macro's parameter list** (host, both profiles), for
  `describe-function`-style help. Returns a fresh copy (fair-use), `nil` for a
  built-in, or an error for a non-function. Backed by an additive kernel
  accessor `fe_fn_params`. `tests/core/introspect.lsp`.
- **`string-search`** (host, both profiles) — index of the first occurrence of a
  needle in a string, or `nil`. **Character-class predicates** `char-whitespace?`
  / `char-digit?` / `char-alpha?` / `char-alphanumeric?` (Core, `60-str.lsp`) over
  char codes — building blocks for word/symbol-boundary scanning.
  `tests/core/str.lsp`.
- **`bound?` and `globals` introspection primitives** (host, both profiles).
  `(bound? sym)` is truthy when a symbol has a non-nil global binding;
  `(globals [prefix])` returns a fresh list of the globally-bound symbols,
  optionally filtered by name prefix. Read-only reflection over the global
  environment (AMOP Ch. 2, "fair use rules"): tools ask the runtime what's
  defined instead of reparsing source. Backed by a new additive kernel accessor
  `fe_symbols()` (read-only view of the interned-symbol list, for host
  introspection only — never handed to Lisp directly). Covered by
  `tests/core/introspect.lsp`.

### Changed
- **Core macros now expand to frozen kernel primitives only** — a macro's
  emitted code (and its expander) no longer rides on a shadowable public Core
  function, so redefining a library name can't silently corrupt a macro (AMOP
  §4.2.2, "Overriding the Standard Method"). `case` expands to an `(or (is …))`
  chain instead of calling `member`; `let*` / `letrec` / `dotimes` / `dolist`
  thread accumulators instead of calling `append` and index with `car`/`cdr`
  instead of `nth`; quasiquote's `,@` splices through `%append` (a load-time
  capture of `append` in `core/10-list.lsp`) instead of the public `append`.
  Behavior is unchanged; robustness is the point. Covered by
  `tests/core/macro-robustness.lsp`; the *Load-bearing prelude (do not shadow)*
  section in `docs/language.md` documents the contract.

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
- **`macroexpand-1`** — inspect one symbolic macro call without evaluating or
  recursively expanding the result. Non-macro forms are returned unchanged.
- **Small error vocabulary** — Core now exposes `error`, `error?`, and
  `error-message` for the tagged error values returned by `try`; the runtime
  adds catchable `(raise message)` for script-authored failures.
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
