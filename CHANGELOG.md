# Changelog

## Unreleased

### Added (binary file I/O)

- **`write-file` / `append-file` now write a blob's raw bytes verbatim, and a
  new `read-blob` reads a file back into a blob.** Previously every value went
  through the string path (`fe_write`), so a blob wrote its printed pointer
  form and any `NUL` byte truncated the output — binary data (images, audio,
  save blobs) could not be written from Lisp even though blobs are documented
  as binary-safe storage. Blobs now bypass the stringifier on write and
  round-trip byte-exact through `read-blob`; non-blob values keep their exact
  prior stringifying behavior. New internal accessors `kec_blob_bytes` /
  `kec_blob_from_bytes` (`host.h`) expose the blob byte buffer to the file
  primitives without duplicating the container layout. (`tests/core/fileio.lsp`.)

### Fixed (arena alignment, GWP-728)

- **`fe_open` now aligns the caller-supplied buffer before carving it into the
  context header and object array.** It previously cast the raw buffer straight
  to `fe_Context*` and then `fe_Object*` with no alignment of its own, so it
  silently required every `kec_open_with_arena` caller to hand it a base that
  happened to be `fe_Object`-aligned. Embedders declare raw `char[]` /
  `uint8_t[]` arenas that land aligned only by BSS/stack-layout luck; when an
  unrelated static shifted the arena to a misaligned address, every `fe_Object`
  access became an unaligned load/store. That is undefined behavior that
  ASan/UBSan trap and that crashed the nOSh Release build on the device (root cause of
  kn-86 GWP-728; a bigger arena did not help because it was alignment, not
  size). `fe_open` now rounds the base up to `max_align_t` and rounds the header
  offset up to `alignof(fe_Object)`, so both the context and the object array
  are always correctly aligned regardless of the buffer's incoming address.
  `fe_min_arena_bytes()` grows by one `max_align_t` to reserve for the skip, so
  `kec_open_with_arena`'s size floor keeps its "just-big-enough buffer still
  opens" contract even on a misaligned base. A C-level test opens a context on
  a deliberately misaligned base (offsets 1..15) and evaluates a Core form;
  under UBSan it traps before the fix and is clean after. (`tests/c/test_arena.c`,
  ctest `c/arena`.)

### Fixed (runtime defect hardening, GWP-700)

A fresh repository review pass after the 2026-07-05 backlog closed (#66–#70).

- **`substring` no longer writes out of bounds when the start index is past
  the end.** The start was clamped low but never against the string length,
  so `(substring "hello" 9 12)` read a byte past the heap materialization and
  wrote `'\0'` through it — heap corruption (ASan-confirmed). Both indices now
  clamp into `[0, length]`; in-range calls keep their exact prior results, and
  a start past the end yields `""` like every other crossed-range case.
  (`tests/core/validate.lsp`.)
- **`string->number` overflow is a defined conversion.** A magnitude beyond
  single-precision range (`"1e39"`) was narrowed double→float while still
  finite — undefined in ISO C11 (6.3.1.5) outside Annex F. Overflow now maps
  explicitly to the float infinity of its sign; the observable result is
  unchanged. (`tests/core/validate.lsp`.)
- **Public evaluation no longer accumulates GC roots across calls.**
  `kec_eval_string` / `kec_eval_file` each left at least one object pinned on
  the Fe root stack, so an embedder that evaluates per event or tick marched
  the stack to its cap — 256 slots on the device — and every later eval died
  with "gc stack overflow" (the desktop's 8192-slot stack masked it). Each
  top-level call now resets to the state's post-open root floor and re-pins
  only its result. **Embedding contract, now documented in `kec.h`:** the
  `out` object stays rooted until the *next* `kec_eval_*` call on the same
  state — use it, or re-root it with `fe_pushgc`, before evaluating again.
  Signatures and valid-input semantics are unchanged. (`tests/c/test_gc_roots.c`,
  ctest `c/gc-roots`.)
- **The generated embed headers compile under strict C11.** `mkembed` emitted
  each embed as one concatenated string literal; ISO C11 only requires 4095
  characters per literal (5.2.4.1) — a pedantic compiler rejects the 32 KB
  Core embed — and MSVC hard-caps literals at 65535 bytes (the editor embed
  is 105 KB). Embeds are now char-array initializers (byte-identical content,
  explicit trailing `0`, `(char)` casts for bytes past 0x7F so signed- and
  unsigned-`char` platforms both compile warning-free). A new ctest
  (`c/embed-portability`) compiles the generated headers with
  `-std=c11 -Wall -Wextra -Wpedantic -Woverlength-strings -Werror` so a
  regression fails in-tree, not downstream.

### Fixed (CLI-host & portability — review sweep, final pass)

Closes the remaining CLI-host and portability defects from the 2026-07-05
repository review (after PRs #66, #67, #68 and the editor-tier pass #69).
This completes the review backlog.

- **`load` resolves relative paths against the loading file's directory**,
  matching the dependency graph `kec build` bundles — the same program no
  longer has two different dependency graphs depending on the CWD. Falls
  back to the old CWD-relative meaning when nothing exists at the
  file-relative candidate (so repo-root-relative layouts, including the test
  suites, keep working); absolute paths and top-level loads (REPL,
  `kec eval`) are unchanged. `require` paths resolve the same way, and
  `kec build` applies the identical fallback, so run and build always bundle
  the same graph. (`tests/cli/load-path.sh`; `docs/language.md` updated.)
- **`kec nemacs` refuses binary (NUL-bearing) files** instead of silently
  destroying data. Fe strings are C strings, so everything after the first
  NUL vanished on open — and `C-x C-s` wrote the truncated content back over
  the original. Now a clear "binary file … refusing to open" error, exit
  nonzero, file untouched. (`tests/cli/nemacs-binary.sh`.)
- **REPL accumulator overflow is loud and clean.** A form larger than the
  16 KB accumulator had its overflowing chunk dropped while `paren_delta`
  was still applied, so a truncated half-form was submitted with "balanced"
  bookkeeping. The whole form is now discarded with an "input too long"
  diagnostic and the accumulator + paren counter reset.
  (`tests/cli/repl-overflow.sh`.)
- **Over-long path/name arguments raise instead of silently truncating.**
  `read-file` / `write-file` / `append-file` / `file-exists?` / `list-dir` /
  `getenv` clipped paths at 4 KB — `write-file` could then write a
  *different existing file*. Same truncate-then-act fix for
  `string->number` / `string->symbol` / `symbol->string`, and for
  `provide` / `provided?` / `require` feature names and `load`/`require`
  paths (the 1 KB registry buffers could dedupe two long names sharing a
  prefix). All raise catchable "… too long" errors. (`tests/core/pathlen.lsp`.)
- **`(args)` is context-owned host state.** argv lived in process-global
  statics shared across every interpreter — the exact class GWP-235/584
  moved into `kec_HostState` (RNG, gensym, now). New `kec_set_args(S, argc,
  argv)` (and `kec_host_state_set_args`) replace `kec_host_set_args`; the
  pointers are borrowed and must outlive the state. `h_args` also no longer
  grows the GC stack per argument (~2 stale roots per arg overflowed the
  device's 256-slot stack around 100 args) — same restore/push idiom as
  `apply`/`read-all` from #68. (`tests/c/test_host_state.c`.)
- **`number->string` computes INT32_MIN's magnitude in unsigned arithmetic.**
  `-(v)` on the in-range value `-2147483648` is signed-overflow UB where
  `long` is 32 bits (the armhf device target). (`tests/core/validate.lsp`.)
- **`kec nemacs` idle loop no longer treats `poll()` EINTR as key-ready.**
  A signal (e.g. SIGWINCH on resize) fell through to the blocking read and
  stalled armed idle timers until the next keystroke; EINTR now retries,
  the way `poll-key` already did.
- **`mkembed` is byte-faithful and checks its output.** It stripped every
  `\r` — including inside Lisp string literals, changing program semantics
  (now escaped as `\r` in the C literal); a NUL byte in an input silently
  truncated the embedded source (now a hard error); and all output was
  unchecked, so a full disk produced a truncated header and exit 0 (now
  `ferror`/`fclose`-checked, nonzero exit, partial output removed).
- **Docs CI blind spot closed.** The `Docs` workflow now runs its build job
  (no deploy) on pull requests touching `docs/**` or `website/**`, so bad
  Starlight frontmatter fails on the PR instead of only after merge.
- **Stale `fe_min_arena_bytes` doc comment fixed** (`kernel/fe.h`): it still
  described the pre-fix "context header only" contract; the floor also
  covers fe_open's own init allocations (~`P_MAX*6+32` object slots).
  Comment-only kernel change.

### Fixed (editor tier — repository review sweep, Emacs-not-vim)
- **End-of-buffer rows render blank, not vi-style `~` markers.** knEmacs
  copies Emacs, never vim (hard product direction); `text-screen` painted
  vim's signature tilde fringe past end-of-buffer. Emacs leaves those rows
  blank; now we do too.
- **Redo moved off `M-/` onto the Emacs 28+ `undo-redo` keys.** In Emacs
  `M-/` is dabbrev-expand, not redo. `text-redo!` now binds `C-M-_` (with
  the `C-?` alias); `M-/` is left unbound, reserved for a future dabbrev.
  The `kec` CLI's key encoder cannot emit either notation yet (ESC+0x1F
  falls through to `"ESC"`; byte 127 is Backspace), so redo is
  table-reachable for other hosts and needs a follow-up encoder branch for
  that TTY.
- **Undo amalgamates like Emacs: inserts cap at 20 chars, deletes coalesce
  too.** Insert coalescing was uncapped (a long typing run became one giant
  undo step) and backspaces/forward-deletes never coalesced (one undo per
  keystroke). Consecutive character edits now group into 20-character undo
  steps in both directions, matching `undo-auto-amalgamate`; opposite-
  direction records never cross-merge.
- **The TTY help strip advertises only keys that are actually bound.**
  `%TTY-HELP` listed `C-M-f/b`, `C-M-d/u`, `C-M-k`, `M-(`, and
  `"C-x C-e eval"` — none resolvable through `editor/55-bindings` or the C
  dispatcher. `'eval-current` stays declared as a host command with a TODO
  to re-advertise once a host wires it.
- **`tty-screen` scrolls the cursor into view.** The body window was taken
  from the top with no offset, clipping a cursor past the visible rows
  off-screen. The structural buffer record gains a persisted `scroll` slot
  (`buffer-scroll`) and `tty-screen` mirrors `text-screen`'s
  recompute-and-persist scroll.
- **`form->view` builds the view tree iteratively.** It recursed to nesting
  depth, exhausting the fixed GC root stack on a deeply nested form (256
  slots on the device; the desktop's 8192 died at depth 500) — defeating
  `buffer->view-lines`' own iterative DFS, which calls it. Now an explicit
  frame stack, same pattern as the DFS.
- **A raising timer thunk no longer aborts co-due siblings.** Each due
  thunk in `timers-advance!` fires under `try`; the raiser's timer is
  dropped (a repeating thunk that raises would otherwise re-raise every
  period — a raise-loop) and the advance returns normally.

### Fixed (error-path leak hardening — review sweep, third pass)

Closes the remaining systematic error-path leak class the repository review
identified (after GWP-235 → PR #52 and GWP-584 → PR #64): heap buffers and
`FILE*`s held across calls that can raise via `fe_error`'s `longjmp` leaked on
the unwind — permanently, on a fixed-arena device that catches errors and
keeps running.

- **A failing `(load)` no longer leaks its `FILE*`.** `fe_read` (syntax error)
  and `fe_eval` (any script error) unwound straight past the `fclose`, so
  repeated failing loads inside `(try)` exhausted the fd table. The load loop
  is now an unwind-protect: a local guard slot closes the file on the error
  path, then re-raises with the original message intact (verified through
  nested loads). Regression lowers `RLIMIT_NOFILE` and hammers failing loads
  (`tests/c/test_error_leaks.c`, ctest `c/error-leaks`).
- **Free-on-error "pending buffer" registry** (`kec_pending_push` /
  `kec_pending_pop`, `host.h`). String primitives must hold a heap
  materialization of their argument across Fe allocations that can raise
  out-of-memory (`fe_string` / `fe_cons` / `fe_read`); the buffer is now
  registered for that window and the runtime error handler frees anything
  still registered before it unwinds. Applied to `substring`,
  `string-append`, `string-split`, `repr`, `read-file` (worst case: a whole
  file body), `read-string`, and `read-all`. `string-ref` and `string-search`
  instead compute their C result first and free *before* allocating — no
  window at all. Restricted by contract to windows that do not evaluate user
  code (an inner caught `(try)` across user code would free an outer frame's
  live buffer — which is why `load` uses the guard-slot pattern instead).
- **Hash growth can no longer raise mid-rehash.** Re-insertion routed through
  `hash_index`/`key_equal`, which heap-materializes long string keys and can
  raise out-of-memory halfway through the move — leaking the old slot array
  and silently dropping every not-yet-moved entry. Entries from the same
  table are already distinct, so the rehash is now a raise-free probe for the
  first empty slot (`key_hash` streams through `fe_write`, no allocation).
  (`tests/core/hash.lsp` covers long-key survival across several growths.)
- **`kec build` closes its nested-load `FILE*`s on a parse error.** The bundle
  guard's `longjmp` abandoned one open `FILE*` per `(load ...)` nesting level;
  the guard now tracks the open stack and the recovery path closes it.
- **`sb_putn` checks `realloc`.** The CLI's growable string buffer dereferenced
  a NULL `realloc` result on OOM (losing the old pointer too); it now fails
  loudly with `kec: out of memory` instead.
- **`kec_open_with_arena` rejects a `> INT_MAX` size with NULL** per the
  `kec.h` contract, instead of narrowing it into `fe_open`'s `int` — the
  wrapped (negative) size faulted before any error handler existed
  (`tests/c/test_arena.c`).
- **`apply` and `read-all` no longer grow the GC stack per element.** Both
  pass-2 reversal loops rooted one cons per argument/form, so a few thousand
  elements overflowed the GC stack (`GCSTACKSIZE` is 256 on the device); they
  now use the same restore/push idiom as their pass 1
  (`tests/core/applyread.lsp`, `tests/core/eval.lsp`).

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
