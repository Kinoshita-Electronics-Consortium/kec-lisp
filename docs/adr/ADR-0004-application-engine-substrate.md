---
title: "ADR-0004: Application-Engine Substrate — General Major Modes & the Minibuffer Command Surface"
description: Promote the editor/REPL tier into the application engine by adding two thin, generic modules — a general major-mode bundle (keymap + render + setup + parent, with keymap inheritance) and the minibuffer command-by-name surface (a command registry + ido-style completing-read). Mode-local buffer state and any per-domain mode are explicitly deferred to "build the first program, then extract."
---

- **Status:** Accepted
- **Date:** 2026-06-26
- **Deciders:** KEC Lisp maintainers
- **Supersedes / superseded by:** Builds on [ADR-0002](ADR-0002-editor-repl-extended-library-tier.md) (the editor/REPL tier) and [ADR-0003](ADR-0003-container-types-vectors-hash-tables.md) (vectors + hash tables). Implements the substrate named by kn-86 **ADR-0046** Decision 2.

## Context

[ADR-0002](ADR-0002-editor-repl-extended-library-tier.md) established a
host-agnostic **editor/REPL extended-library tier** above Core — zipper, buffer,
view, keymap-as-data, lifecycle, ranker, REPL — `provide`-gated so the device
prelude stays minimal. [ADR-0003](ADR-0003-container-types-vectors-hash-tables.md)
landed the vectors + hash tables that back it.

The consumer of that tier — the KN-86 — has since decided (**kn-86 ADR-0046**)
that **knEmacs is the application engine, not merely the editor**: the deck's
first-party data-tier programs are *modes* on one shared substrate, so navigation,
command-by-name, and completion are solved **once** on a 34-key device instead of
re-invented per program. ADR-0046 **Decision 2** names the app-agnostic substrate
to build framework-first — explicitly *non-speculative* because every program
shares it — and **Decision 4** (with Option C) forbids building a *per-domain*
framework before its first app: build the concrete program, then extract.

Two pieces of that substrate are missing from today's tier:

1. **A "mode" is only a keymap.** `editor/50-keymap.lsp` registers a keymap per
   mode-scope in `*keymaps*` and dispatches through it (`mode-dispatch`). There is
   no notion of a mode as a *bundle* — a keymap **plus** a render function, a
   setup function, and a parent to inherit keys from. ADR-0046's "programs as
   modes" needs that bundle as the unit a program specializes.
2. **There is no minibuffer / command-by-name surface.** The ranker
   (`editor/80-ranker.lsp`) scores candidate *tokens*, but nothing drives an
   "M-x": no command registry, no `completing-read`, no minibuffer state. ADR-0046
   Decision 2 names "the minibuffer / completion / command-by-name surface"
   explicitly, and commits **ido-style incremental narrowing** as the grammar
   (a Spotter-style object-result search is a noted upgrade path, *not* adopted).

This ADR closes exactly those two gaps — and nothing more.

## Decision

Add **two thin, generic, additive** modules to the editor tier. No kernel change,
no new C primitive, no change to any existing module's behavior. Both are
`provide`-gated tier files, headlessly evaluable under `kec test`, and iterative
throughout (the device GC stack is 256).

### 1. `editor/52-mode.lsp` — general **major modes** (loads after 50-keymap, before 55-bindings)

A major mode is a small bundle *over the existing keymap registry*. It is a
**class**, not an instance: keymap + render + setup + parent. Mode-local STATE is
deliberately **out of scope** (Decision 4 — extracted with the first program).
Handlers keep the existing `(handler st) -> st` contract; render is `st ->
view-model`; setup is `() -> st` (initial state) or `st -> st`.

- `(define-major-mode name opts)` — `opts` is a plist
  `(:keymap km :render render-fn :setup setup-fn :parent parent-name)`, all
  optional. Stores a record in a module `*major-modes*` hash **and** calls
  `register-keymap` so the existing `mode-dispatch` keeps working. Returns `name`.
- Accessors: `major-mode`, `major-mode-keymap`, `major-mode-render`,
  `major-mode-setup`, `major-mode-parent`, `major-mode?`, `major-mode-list`.
- **Keymap inheritance:** `major-mode-handler` resolves a token by checking the
  mode's own keymap, then walking the `:parent` chain — child overrides parent;
  unbound everywhere = nil. The walk is **bounded** (`MAJOR-MODE-MAX-DEPTH`), so a
  malformed parent cycle terminates instead of looping.
- `major-mode-dispatch` — like `mode-dispatch` but inheritance-aware (via
  `major-mode-handler`); unbound token / unknown mode is a no-op returning `st`.
- `major-mode-enter` — runs the mode's setup (applied to `st`, so both setup forms
  work under Fe's arity tolerance) and returns the resulting state; nil setup
  returns `st` unchanged.

### 2. `editor/85-minibuffer.lsp` — **completing-read + command-by-name** (loads after 80-ranker, before 90-repl)

The M-x surface, reusing the ranker's `string-less?` for ordering and Core's
`string-prefix?` / `string-contains?` for matching.

- **Command registry:** a module `*commands*` hash, name-string -> fn, with
  `define-command`, `command`, `command?`, `command-names`.
- **`completing-read candidates query`** — ido-style incremental narrowing: empty
  / `nil` query returns ALL candidates (in input order); otherwise matches are
  ordered **prefix-matches first, then substring matches**, each group
  alphabetical. Deterministic, iterative.
- **Minibuffer state** — a vector `[prompt input candidates]`:
  `make-minibuffer`, `minibuffer-update`, `minibuffer-matches`,
  `minibuffer-default`, and the `minibuffer-prompt` / `minibuffer-input`
  accessors.
- **`execute-command name . args`** — looks up `name` in `*commands*` and applies
  the fn; raises a clear error if unknown.
- **`read-command query`** — `completing-read` over `(command-names)`; returns the
  narrowed list (the host picks one and calls `execute-command`).

### 3. Explicitly deferred (per kn-86 ADR-0046 Decision 4)

- **Mode-local buffer state** — a mode here is a class (keymap + render + setup +
  parent). Per-instance buffer-local variables wait for the first concrete
  program that needs them, then are extracted.
- **Any concrete program mode or per-domain library** (a spreadsheet mode, an
  outline library, a dired-style commander, …). Substrate only — building one now
  is the speculative generality Option C rejects.
- **Spotter-style object-result search.** The committed grammar is ido-style
  narrowing; a richer drill-down search is a noted upgrade path, not a decision.

## Consequences

- The editor tier gains the two substrate pieces ADR-0046 Decision 2 names, so the
  KN-86 (and any host) can build programs-as-modes on `provide`-gated KEC Lisp
  with no firmware fork.
- Both modules are additive: the frozen kernel is untouched, no existing module
  changes behavior, and the existing `*keymaps*` / `mode-dispatch` path keeps
  working because `define-major-mode` registers its keymap there.
- The tier ships one small flat-plist reader (`%plist-get`, module-local) because
  Core ships only the *alist* `get` and the symbol-property `get-prop`; `opts` is
  a flat plist by the brief's public surface.
- The new modules are embedded with the rest of the editor tier, so `kec nemacs`
  carries them; they cost nothing to a context that never references them.

## Acceptance criteria

1. `ctest` green on ubuntu + macos; two new conformance suites
   `tests/editor/mode.lsp` and `tests/editor/minibuffer.lsp` registered in the
   editor-test `foreach` and passing.
2. `editor/52-mode.lsp` covers: define + accessors; `major-mode?`; child keymap
   overrides parent; child falls through to parent; unbound-everywhere is a no-op;
   `major-mode-enter` runs setup; a parent cycle terminates (bounded walk).
3. `editor/85-minibuffer.lsp` covers: the command registry; `completing-read`
   (empty = all, prefix narrows, substring after prefix, no-match = empty,
   deterministic ordering); minibuffer update/matches/default; `execute-command`
   runs + raises on unknown; `read-command` end-to-end.
4. Both modules are slotted into `EDITOR_SRCS` at their sorted positions and
   end with `(provide 'editor/mode)` / `(provide 'editor/minibuffer)`.
5. No concrete program mode or per-domain library is added; mode-local buffer
   state is deferred.

## References

- [ADR-0002: Editor/REPL Extended-Library Tier](ADR-0002-editor-repl-extended-library-tier.md) — the tier this extends (modes, keymaps, ranker, lifecycle).
- [ADR-0003: Container Types — Vectors & Hash Tables](ADR-0003-container-types-vectors-hash-tables.md) — the hash tables backing `*major-modes*` / `*commands*` and the vector records.
- **kn-86 ADR-0046: knEmacs is the application engine** — the consumer; Decision 2 names this substrate as non-speculative, Decision 4 + Option C defer per-domain modes to "build the program, then extract."
- `editor/50-keymap.lsp` (`*keymaps*` / `register-keymap` / `keymap-handler` / `mode-dispatch`), `editor/80-ranker.lsp` (`string-less?`), `core/65-strtool.lsp` (`string-prefix?` / `string-contains?`).
