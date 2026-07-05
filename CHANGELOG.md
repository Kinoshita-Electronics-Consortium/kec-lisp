# Changelog

## Unreleased

### Fixed (repository review sweep)
- **The writer escapes backslashes in strings** (kernel delta, `fe.c`).
  `fe_write` escaped only `"`, so any string containing `\` re-read wrong —
  `kec build`, which round-trips every bundled form through the writer,
  silently deleted backslashes from shipped `.kec` bundles, and a string
  *ending* in `\` produced an unparseable bundle. `repr` output now re-reads
  to the identical string (`tests/core/str.lsp` round-trip checks).
- **`equal?` walks the cdr spine iteratively.** It recursed per element, so
  lists past the GC stack depth (~100 elements on the device's 256-slot
  build) crashed with "gc stack overflow" — and the editor tier calls it on
  every REPL submission (history dup-coalescing). Recursion now only descends
  into cars; 2000-element lists compare fine (`tests/core/alist.lsp`).
- **A raising test can no longer pass CI green.** `deftest` runs its body
  under `try` (a raise = one failed check, later tests still run) and
  `kec test` exits nonzero when a file aborts mid-load. Previously a raise
  aborted the file, the driver printed "ERROR loading" — and still exited 0.
  This immediately exposed `tests/core/rng.lsp` asserting the pre-GWP-584
  `(rand-int 0)` → `0` contract (directly contradicting
  `tests/core/validate.lsp` in the same suite); updated to the current
  raise-on-empty-domain contract. New `cli/test-exit` ctest pins both paths.
- **`read-file` rejects non-seekable files instead of corrupting the heap.**
  `ftell` returning -1 (FIFO, `/dev/stdin`) flowed into `malloc`/`fread`,
  writing stream content into a zero-byte buffer. Now a catchable
  "not a seekable file" error.
- **`fn-params` is GC-safe.** `copy_spine` un-rooted the freshly copied tail
  before the outer `fe_cons`; a collection triggered by that cons could sweep
  the copy and return recycled cells. The cons now happens under the roots.
- **The REPL pretty-printer survives improper lists.** `%pp-break` called
  `car` on a dotted tail, and `repl-submit` only guarded *eval* — so a wide
  dotted-pair result raised out of the loop, violating the L6.5
  loop-survives contract. Dotted tails now render as a `. tail` line, and
  result *formatting* runs under `try` (a printer failure lands a
  `print-error:` entry instead of killing the session).

### Fixed (language hardening, GWP-584)
- **Container constructors no longer leak backing memory on arena exhaustion.**
  Every constructor allocated its C backing before `fe_ptr_typed`; an
  out-of-memory `longjmp` there leaked the backing — permanently, on a
  fixed-arena device that catches errors and keeps running. The kernel gains
  the additive `fe_set_ptr` (replace an `FE_TPTR`'s pointer) and construction
  is now two-phase: pointer object first (the only step that can raise), then
  the backing, owned by the gc handler from the moment it exists. A C
  regression churns constructors at arena saturation with a counting allocator
  and asserts alloc/free balance (`tests/c/test_host_state.c`).
- **Hash string keys hash and compare by their full content.** Keys were
  rendered through fixed 1024-byte buffers, so two long keys sharing a
  1023-byte prefix were silently the *same* key — contradicting the language's
  content equality for strings. The hash now streams FNV-1a through `fe_write`
  (no ceiling) and equality is a length probe plus exact byte compare (stack
  fast path below 1 KiB). The "first 1024 bytes" caveat is gone from
  `docs/language.md` and amended in ADR-0003.
- **Integer-taking string/system primitives validate their inputs.**
  `string-ref` / `substring` indices, `string-split` separators and
  `char->string` codes (bytes 0..255), `number->string` radixes (integer 2..16;
  non-decimal renderings also require an exact integer value), and `exit`
  codes now raise a catchable error on fractional, non-finite, or out-of-range
  numbers instead of silently truncating — or hitting the undefined float→int
  cast. `poll-key` rejects a NaN timeout (it slipped past both range guards
  into the very `(int)` cast the guards exist to prevent). `rand-int` requires
  a **positive** bound instead of inventing `0` for an empty `[0, n)` domain.
  Valid calls keep their exact previous results (`tests/core/validate.lsp`).
- **`gensym` numbering is context-owned.** The counter was a process-global
  static, so a fresh context's symbol names depended on how many contexts came
  before it in the process. It now lives in `kec_HostState`; fresh contexts
  always number from the same origin.
- **`(now)` measures from a per-context baseline** captured at open, instead of
  returning raw `CLOCK_MONOTONIC` (seconds since machine boot) whose
  single-precision rendering decays to ~62 ms resolution after ten days of
  uptime. Seconds-since-open stay sub-millisecond for the life of any session;
  the monotonic never-backward contract is unchanged (ADR-0005 amended).

### Changed (language hardening, GWP-584)
- **Shared conversion helpers in `host.h`.** The checked integer/byte
  narrowing (`kec_checked_int` / `kec_checked_byte`) and length-aware
  stringify (`kec_strlen_obj` / `kec_strdup_obj`) previously existed as two
  and three private copies across `host.c`, `containers.c`, and `kec.c`; they
  are now one public seam that downstream device primitives can (and should)
  reuse — see `docs/ffi-bridge.md`.

### Added
- **knEmacs idle-timer — animation inside the editor** (ADR-0006; GWP-643).
  `editor/72-timer.lsp` adds a clock-free timer registry (`run-with-timer` /
  `cancel-timer` / `timers-advance!` / `timers-poll-ms`; the host owns the clock
  and passes `now` in, so it is mock-clock testable). The `do_nemacs` loop now
  `poll()`s stdin with a timeout computed from the next armed timer and fires the
  due idle thunks on timeout — repainting between keystrokes. With nothing armed
  the timeout is `-1` (block forever), so the no-timer path is byte-identical to
  before. A one-shot `KN86_NEMACS_INIT` startup hook (a Lisp expression) can arm
  timers / preload config. Hardened against busy-spin: a non-positive `repeat`
  normalizes to a one-shot (in KEC `0` is truthy), the host floors its poll
  interval to 10 ms (so a sub-ms repeat ticks at ~100 Hz, never spins) and caps
  it at 1 day, and a timer-registry error degrades to a blocking wait rather than
  a 0 ms spin. (`tests/editor/timer.lsp`, `tests/cli/idle-timer-smoke.sh`.)
- **Keyboard input — `read-key` / `poll-key`** (GWP-642; `docs/ffi-bridge.md` §4).
  Terminal input bound from the `kec` CLI (`cli/main.c`), reachable from `kec run`
  and the editor: `(read-key)` blocks for one input byte (`nil` at end-of-input);
  `(poll-key secs)` waits up to `secs` (a `poll()` on stdin) and returns the byte
  or `nil`. CLI-specific, **not** portable `host.c` — the device firmware
  registers the same Lisp names over its own input (HID/evdev). The editor's
  keystroke reads moved `getchar()` → `read(2)` so stdio buffering can't defeat a
  future `poll()`. (`tests/cli/readkey-smoke.sh`.)
- **Pure math + monotonic time primitives** (ADR-0005; GWP-641). Always-on host
  primitives `sin` / `cos` / `tan` (radians) and `atan2` `(y x)`, plus `pi` / `tau`
  Core constants (`core/15-math.lsp`), and `now` — a monotonic wall clock
  (`CLOCK_MONOTONIC`) distinct from the CPU-time `clock`. Registered beside
  `sqrt` / `pow` / `clock`, before the FULL gate (they touch no host resource).
  Single-precision contract: results carry ~1e-7 error — epsilon-test only, never
  exact `(is …)`. (`tests/core/math.lsp`, `tests/core/time.lsp`.)
- **Application-engine substrate — general major modes + the minibuffer
  command-by-name surface** (ADR-0002, ADR-0004; kn-86 ADR-0046 Decision 2). Two
  thin, generic editor-tier modules promote knEmacs from "the editor" toward the
  shared **application engine** every program-as-mode rides. `editor/52-mode.lsp`
  adds **major modes** as a small bundle over the keymap registry —
  `define-major-mode` (a `:keymap`/`:render`/`:setup`/`:parent` plist), the
  `major-mode*` accessors, **keymap inheritance** (`major-mode-handler` /
  `major-mode-dispatch` walk the `:parent` chain, child overrides parent, with a
  bounded cycle guard), and `major-mode-enter` (runs the mode's setup). A mode is
  a *class* — keymap + render + setup; mode-local buffer state is deliberately
  deferred ("build the first program, then extract", ADR-0046 Decision 4).
  `editor/85-minibuffer.lsp` adds the **M-x surface**: a `*commands*` registry
  (`define-command` / `command` / `command?` / `command-names`), ido-style
  **`completing-read`** (empty query = all; prefix matches first, then substring,
  each group alphabetical — reusing the ranker's `string-less?`), a minibuffer
  state record (`make-minibuffer` / `-update` / `-matches` / `-default`),
  `execute-command`, and `read-command`. Headless and iterative throughout.
  `tests/editor/{mode,minibuffer}.lsp` (+59 checks). No concrete program mode is
  built — substrate only.
- **Native matrices and binary blobs.** Containers now include flat row-major
  matrices (`make-matrix`, `matrix-ref`, `matrix-set!`, dimensions, predicate,
  and iterative Core helpers) and binary-safe byte blobs (`make-blob`,
  `blob-ref`, `blob-set!`, length, predicate). Both use the context-owned
  container allocator and typed `FE_TPTR` lifecycle; matrix entries are marked
  through GC and blob bytes are freed on sweep/teardown.
- **Editor input layer — literal entry, arrow keys, eval-current, structural REPL
  prompt** (ADR-0002, L3.2/L4.2/L4.5/L1.5). The buffer gains **literal entry**
  (`buffer-enter-literal!` / `-literal-push!` / `-backspace!` / `-commit-literal!`
  / `-cancel-literal!` / `buffer-in-literal?`) — type a value, then commit it as a
  leaf or cancel — and **`buffer-current-form`** (the top-level form containing the
  cursor, for eval-current). A new **`:repl-prompt`** mode (`editor/92-prompt.lsp`)
  makes the REPL prompt itself a structural buffer: compose the input form with the
  editor verbs, `EVAL` submits it to the REPL engine and resets the prompt. In
  `kec nemacs`: `i` now enters live literal entry (echoed in the echo line), **arrow
  keys** navigate (↑↓ siblings, →/← descend/ascend), and `e` evaluates the current
  top-level form. `tests/editor/{buffer,prompt}.lsp` (+10 checks);
  `tests/cli/edit-smoke.sh` covers literal insert.
- **`string-split`** (host, both profiles) — `(string-split s sepcode)` splits a
  string on every occurrence of a byte (a char code, as `string-ref` returns) in
  one O(n) pass; N separators yield N+1 segments. The char-level sibling of
  `string-ref`/`substring`. Core `split` and the knEmacs line splitter
  (`%split-lines`) are rewritten on top of it.

### Fixed
- **knEmacs file-open is no longer O(n²).** `%split-lines` (and Core `split`) used
  `(string-ref s i)` per index, and `string-ref` restringifies the whole object
  each call, so opening a ~70 KB file hung for ~23s. Now linear via `string-split`
  (instant). `tests/cli/nemacs-smoke.sh` adds a >64 KB byte-exact round-trip.
- **knEmacs save is byte-exact and never accretes a trailing line.** `C-x C-s`
  routes through the length-aware `write-file` instead of a fixed 64 KB C buffer
  (no silent truncation past 64 KB) and writes the buffer verbatim — the old
  unconditional trailing `\n` grew the file by a blank line on every save. A
  successful save also clears the modeline `*`.
- **knEmacs `C-x C-c` guards unsaved edits.** Quitting a modified buffer now
  prompts (y saves / n drops / C-g cancels) instead of discarding silently.
- **knEmacs vertical motion keeps a goal column.** `C-n`/`C-p` now remember the
  desired column: passing through a short line clamps the visible column but
  restores it on the next long line, instead of destructively forgetting it. A
  horizontal move or edit sets a new goal.
- **knEmacs scrolls long lines horizontally.** The text window pans so point
  stays visible and the cursor parks within the window, instead of running off
  the right edge on lines wider than the terminal.
- **knEmacs `Tab` indents** to the next width-2 tab stop with soft spaces (kept
  in sync with the fixed grid), instead of beeping "TAB is undefined".

### Added (knEmacs undo)
- **knEmacs undo/redo, command-based.** Each edit records its inverse operation
  (an insert/delete span) rather than a whole-buffer snapshot, so history is cheap
  on large files. `C-/` / `C-x u` undo, `M-/` redo; consecutive typing coalesces
  into one undo step; a fresh edit clears the redo stack. Bounded history (512
  records). The edit ops are split into raw mutators (`%text-raw-*`) and recording
  wrappers so undo replay never re-records. `tests/editor/text.lsp` covers
  insert/newline/backspace/forward-delete/join undo, redo, coalescing, and
  redo-clear; the nemacs smoke covers a type→undo→redo round-trip.
- **knEmacs mark / region / kill / yank.** `C-Space` sets the mark; `C-w`
  kills the region (mark…point), `M-w` copies it, `C-k` kills to end of line
  (or the newline at EOL), `C-y` yanks the most recent kill. Bounded kill ring;
  each kill/yank is one undo step. New buffer slots `mark` and `kill`; the host
  maps the NUL byte (terminal `C-Space`) to `C-@`. `tests/editor/text.lsp` covers
  kill/copy/yank, multiline + reversed regions, kill-line (incl. EOL join), and
  kill-region undo; the nemacs smoke covers C-@/C-w/C-y. `M-y` yank-pop deferred.
- **knEmacs incremental search (`C-s`).** A host minibuffer loop drives a Lisp
  search engine (`text-search-forward` / `text-search-move!`): typing extends the
  pattern (re-search from the origin), `C-s` repeats forward from point, `DEL`
  shrinks, `RET` accepts (the match becomes the region — mark at start, point at
  end), `C-g` cancels and restores point. Single-line patterns; `C-r` reverse and
  wraparound deferred. `tests/editor/text.lsp` covers search-forward (hit/miss,
  from-offset), search-move point/mark, and empty-needle; the nemacs smoke drives
  a C-s/type/accept/edit round-trip.

### Changed
- **Load-bearing standard globals are protected from rebinding.** Kernel
  primitives, host/runtime primitives, Core functions/macros, and private Core
  helper bindings such as `%append` are frozen after Core loads. Attempts to
  `set` them or clobber them with a top-level `let` raise a catchable error and
  leave the standard method table intact; mutable registries such as `%plists`
  remain writable by their owning functions.
- **Recent language additions hardened for embedding** (GWP-235). Runtime error
  recovery and SplitMix64 RNG state are now per interpreter. Containers use
  composable typed-`FE_TPTR` lifecycles and remember the context allocator/free
  pair that created each backing; firmware pointer types can coexist without
  handler replacement or unsafe pointer probing. `bound?`/`globals` now
  distinguish unbound symbols from symbols bound to `nil`, so `defvar` preserves
  nil-valued configuration. `read-string` is length-aware; vector/bitwise/RNG
  integer inputs reject lossy narrowing; padding requires one fill character.
  New C embedding regressions cover multiple contexts, allocator ownership,
  typed pointer composition, and long-form reading.
- **CLI command naming corrected:** `kec repl` (and bare `kec`) is the **strong
  REPL** (history, completion, pretty-print, error recovery); **`kec nemacs [FILE]`**
  is the **knEmacs structural editor**. (`kec edit` stays as an alias for `kec nemacs`.)
  The old basic line REPL is superseded by the engine-backed one.
- **REPL pretty-printer is now structurally indented** (`editor/90-repl.lsp`).
  `repl-format` breaks a result wider than the host width into nested lines
  **indented by depth** (a sub-form that fits stays inline), instead of the
  previous flat one-element-per-line. Recursion is depth-capped (deeper structure
  prints flat-truncated) so it stays GC-stack-safe on the device, and the whole
  result honors a line budget with a `... (N more lines)` note.

### Added
- **`kec nemacs` — the structural-editor TTY surface** (`editor/40-view.lsp`
  `buffer->view-lines`, `editor/96-tty.lsp`, `cli/main.c`; ADR-0002). An
  interactive terminal structural editor over the engine: it renders the buffer's
  view model each frame (an inverted modeline, the s-expression tree with the
  cursor line in reverse video, an echo hint) and dispatches keystrokes through
  the `:nemacs-nav` keymap — `h`/`j`/`k`/`l` move (ascend / next / prev /
  descend), `w` wrap, `s` splice, `d` delete (cut), `t` transpose, `u` undo,
  `e` eval the focused form, `i` insert, `W` save, `q` quit. The new
  `buffer->view-lines` is the abstract line view model (depth / label / cursor
  per row, SEAM S4); `editor/96-tty.lsp` is the ANSI painter (terminal host
  layer). Raw-mode terminal handling in C; everything structural is driven from
  the Lisp tier. `tests/editor/tty.lsp` (13 checks) + `tests/cli/edit-smoke.sh`
  (drives the keymap over piped keystrokes, serializes the edit back).
- **`kec repl` — the strong REPL reference host** (`editor/95-host.lsp`,
  `cli/main.c`; ADR-0002, WS6). The editor/REPL tier is embedded in the binary
  (`KEC_EDITOR_SRC`) and a new `kec repl` subcommand drives the REPL engine over
  the terminal: read a paren-balanced form, hand it to `host-repl-line`, print the
  engine's formatted output; history ring, structural pretty-printer, and error
  recovery all come from the Lisp tier. Live completion from the global image
  (`host-complete` over `globals`, dogfooding the ranker — SEAM S8). This is both
  the strong standalone REPL and the **device-free proof that the SEAM (S1–S9)
  carries the whole engine with no new C seam**; the firmware provides its own
  host the same way. Prompts/banner on stderr so stdout is scriptable.
  `tests/editor/host.lsp` (11 checks) + `tests/cli/nemacs-smoke.sh` (end-to-end).
- **Editor tier — REPL engine** (`editor/90-repl.lsp`; ADR-0002, L6). The
  host-agnostic read-eval-print loop: READ a well-formed form (composed via the
  structural editor), EVAL against the host eval-fn (SEAM S1) under a
  non-propagating error handler (a failing form keeps the loop alive and
  preserves the input for retry), PRINT via `repl-format` (opaque values → `#<type>`
  tags, canonical numbers, a result wider than the host width broken over lines).
  The in-memory history ring (drop-empty, coalesce-consecutive-duplicates,
  saturate-and-evict-oldest) + walking (`repl-older!` / `repl-newer!` /
  `repl-recall` / `repl-reeval!`) with a default `:repl-history` keymap; a
  guided-prompt (tutorial) runner mechanism that does not consume history (L6.7).
  `make-repl` / `repl-submit`. `tests/editor/repl.lsp` (33 checks).
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
  typed `FE_TPTR` foreign objects with GC-integrated backing (a composable
  lifecycle keeps contents alive and frees backing on sweep and `fe_close`).
  Primitives: `make-vector`, `vector`, `vector-ref`, `vector-set!`,
  `vector-length`, `vector?`; `make-hash-table`, `hash-set!`, `hash-ref`,
  `hash-has?`, `hash-del!`, `hash-count`, `hash-keys`, `hash-table?`. Core
  helpers: `vector->list`, `list->vector`, `vector-fill!`, `vector-copy`,
  `vector-map`, `vector-for-each`, `hash-values`, `hash->alist`, `alist->hash`,
  `hash-for-each`. Hash keys are numbers (by value), symbols (by identity), or
  strings (by content); other key types raise. Backing memory uses a context
  allocator (`kec_set_container_allocator_for`) defaulting to malloc/free, and
  each allocation retains its matching free callback. A no-libc device installs
  its fixed-pool or bump allocator explicitly. `tests/core/{vector,hash,container-gc}.lsp`
  plus `tests/c/test_host_state.c`.
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
  `(bound? sym)` is truthy when a symbol has a global binding, including `nil`;
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
