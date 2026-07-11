---
title: "ADR-0002: Editor/REPL Extended-Library Tier (knEmacs core in KEC Lisp)"
description: The host-agnostic structural editor + REPL engine — tree buffer, cursor, keymap-as-data, dispatch, token ranker, REPL loop, serialize/load, lifecycle — lives in KEC Lisp as a provide-gated extended-library tier above Core. Only device concerns stay in the KN-86 firmware, bound through an abstract host seam.
---

- **Status:** Accepted (amended — see below)
- **Date:** 2026-06-21
- **Deciders:** KEC Lisp maintainers
- **Supersedes / superseded by:** Amends ADR-0001's container deferral (see Decision §4 → ADR-0003).
- **Amended (#56):** knEmacs's editing surface is now a real **text buffer**
  (`editor/32-text.lsp` — lines of characters with a point), not the s-expr
  tree/zipper described below. The zipper (`editor/10-zipper.lsp`) is retained
  as the backing for the `kec repl` structural prompt, and the "buffer is a
  tree, unbalanced parens cannot exist" invariant no longer applies to knEmacs.
  The tier partition (LIB/SEAM/DEVICE) and everything else here still stands.

## Context

The KN-86 needs **knEmacs** (the on-device structural editor, formerly nEmacs)
and a first-class onboard **REPL**. The kn-86 program manager produced a
requirement partition that splits every editor/REPL requirement three ways:

- **LIB** — the host-agnostic core: s-expression trees, cursors, keymaps-as-data,
  evaluation, reader/printer, ranking, and *abstract* input/render/store.
- **SEAM** — what LIB requires *from* any host, stated in device-free terms.
- **DEVICE** — what stays in / is added by the KN-86 firmware (CIPHER-LINE, the
  physical key matrix, deck state, missions, surfaces, persistence backing).

The **boundary test** for LIB — *"runs under `kec` on a laptop with no KN-86
hardware"* — is **the boundary this repo already uses** ([boundary.md](../boundary.md)).
A source-verified evaluation (against `kernel/`, `core/`, `host/`,
`runtime/kec.c`, and the [knEmacs field notes](../notes/field-notes-writing-gnu-emacs-extensions.md))
found the LIB partition is **~95% expressible on today's substrate with no kernel
changes and no new host C primitives for a correct v1**: it rides
`read-string`/`read-all`/`eval`/`apply`, `try` + the `core/36-recover` macros,
`repr`/`princ`, the `core/25`+`26` alist/plist surface, `sort` + the HOFs, the
`core/60`+`65` string toolkit, `gensym`, and `equal?`. The
[`black-ice-trace`](../../examples/black-ice-trace-lib.lsp) example already proves
a stateful, command-driven app runs in pure KEC Lisp over alist records.

The only structural tension was containers: ADR-0001 deferred vectors/hash
tables. Everything LIB needs *can* be expressed on cons/alists (the device sizes
are tiny — a 16-entry history ring, 34-key keymaps, a top-8 candidate list), so
containers are a performance optimization, not a correctness blocker. But since
the sprint that follows this ADR targets the device — where the ranker's
per-render latency and O(1) rings/grids matter — we choose to build containers
**now** rather than ship v1 on O(n) lists (see §4).

## Decision

### 1. Establish an editor/REPL **extended-library tier** in this repo

A new tier sits **above Core**, host-agnostic, **`provide`-gated** so the embedded
device Core stays minimal and the CLI / firmware opt in by loading it. It is the
home of the LIB partition:

| LIB block | What the tier owns |
|---|---|
| **L1** Buffer & cursor | The s-expr **tree buffer** (root form sequence), a **cursor** as a Huet-style zipper over cons cells, the **clipboard** (captured subtree), the modified flag, the REPL buffer variant (prompt + immutable history), and the buffer-name field. The **well-formedness invariant is free — the buffer is a tree, not text**, so unbalanced parens cannot exist. |
| **L2/L3** Keymap & modes | Keymap as **nested alist** keyed by **abstract command tokens** (`CAR`, `EVAL`, …); dispatch = lookup + `eval`; three handler slots (`:tap`/`:double-tap`/`:long-press`); the `define-key`/`keymap-*` surface; five mode scopes (`:nemacs-nav`, `:nemacs-literal`, `:repl-prompt`, `:repl-history`, `:grab`); cursor-position selects the active mode. Dispatch is **headlessly evaluable** (pure lookup + eval). |
| **L4** Structural verbs | Navigation (`descend`/`next-sibling`/`prev-sibling`/`ascend`/`descend-to-leaf`), insertion, manipulation (`delete`/`grab`/`paste`/`wrap`/`splice`/`lift`/`transpose`), introspection (type/parent/position), and `eval-current` against the host context. |
| **L5** Token ranker | A **static, deterministic** ranker (no ML): legal-form filter by position, the documented scoring (domain +5 / local +3 / recency / popularity / semantic-fit, alphabetic tiebreak), top-8, no shadowing of builtins, externally-fed vocabulary. One ranker drives REPL completion and the nEmacs palette. |
| **L6** REPL loop | Read (structural compose, submit on `EVAL`) / Eval (against the host context, with a non-propagating error handler) / Print (printer + a **structural pretty-printer over a host-supplied line budget**); the in-memory **history ring** + walking semantics; recoverable + unrecoverable error paths; the guided-prompt (tutorial) runner *mechanism*. |
| **L7** Persistence | The **(serialize, load) pair** only: serialize the buffer to printable, NUL-terminated s-expression text (empty → `()`, overflow → 0); load by parsing with the reader, replacing the root, resetting the cursor. **The host owns the bytes.** |
| **L8** Lifecycle | The lifecycle state machine (`init`/`shutdown`/`enter-editor`/`enter-repl`/`exit`/`set-mode`) and the **hooks** the host subscribes to. The library performs **no** device side effects itself. |
| **L9** Memory | Operates entirely within the host-provided arena; the tier's own keymaps/zipper/ring consume the same pool (the arena-inversion constraint is *measured*, not new infrastructure). |

### 2. The SEAM is a set of **Lisp** seams — no new C seam beyond `kec_bind_fe`

LIB depends only on these abstract host capabilities; none may carry device
vocabulary:

| Seam | What the host supplies |
|---|---|
| **S1** Evaluation context | The KEC context + **which primitives are bound** into it — *this is the capability mechanism*; LIB evals against whatever the host bound. (Already the embedding model: `kec_Profile` + `kec_bind_fe`.) |
| **S2** Input events | `(command-token, event-type ∈ {tap, double-tap, long-press})`. The host owns all timing classification; LIB never sees raw timing. |
| **S3** Text input | Committed characters/strings into the active literal slot, plus commit/cancel. *How* characters are produced (multi-tap, real keyboard) is the host's concern. |
| **S4** Render sink | LIB emits an **abstract view model** (structural spans, line layout, highlight/bracket markers, modeline fields, palette list, echo, error markers); the host paints it. **(Decision: the view model lives in LIB — see §3.)** |
| **S5** Byte store | The destination/source for serialized buffer + history text (LIB hands over / ingests strings only). |
| **S6** Lifecycle subscription | Registration for enter/exit/mode-change hooks. |
| **S7** Effect cue | Renders an error/confirm cue when LIB raises an "invalid move / boundary" signal. |
| **S8** Vocabulary feed | Pushes domain vocabulary + grammar productions into the ranker; clears on scope change. |
| **S9** Config values | Tunable constants: arena envelope, history-ring capacity, serialize cap, output width. LIB carries no device numbers. |

### 3. The structural **view model lives in LIB** (S4 boundary decision)

LIB emits an abstract span/line view model; the host paints pixels/cells. The
alternative — LIB emits only the tree and DEVICE does all formatting — strands
the most reusable logic (structural pretty-print, highlight/bracket placement) in
firmware and prevents a laptop `kec` TUI from painting the same model. Keeping the
view model in LIB keeps the reuse line clean and keeps that logic under `kec test`.

### 4. Build containers **now** (amends ADR-0001's deferral)

Vectors and hash tables are pulled forward from ADR-0001's "deferred" list and
specified in **ADR-0003**. They back the history ring (L6), the cell grid, undo,
and the ranker's vocabulary index (L5), and they de-risk the ranker's per-render
latency target under the tree-walking interpreter. LIB is **not** sequenced behind
them — it can ship on cons/alists — but building them in parallel means the
device-targeted modules use O(1) structures from the start.

### 5. Multi-tap and the rest of DEVICE stay in the firmware

The Nokia multi-tap input method, physical key→token mapping + tap/double/long
timing, CIPHER-LINE / main-grid surface painting, persistence backing (Universal
Deck State ring, cart SD `/save/`), the cart grammar/vocabulary FFI
(`emacs-extend-grammar`/`-vocabulary`, `prompt-text`, `launch-app`), the Mission
Runner binding-set, and the tutorial content + first-boot gating remain in
`kn-86`, layered on the tier via the SEAM.

## Deferred (accepted in principle; later ADRs/sprints)

- **Node-precise eval errors** — enriching `eval-current` to identify the
  offending node needs richer-than-message errors (pairs with ADR-0001's deferred
  typed errors). v1 is best-effort node identity.
- **Regex + syntax tables** — sexp/word motion beyond the structural verbs; the
  deferred "expensive tier" from the field notes.
- **Advice / instrumentation** (Edebug-/ELP-style) — wants mutable function
  bindings; verify before betting on it.
- **Reader syntax for containers** — vectors are runtime objects, not `[...]`
  literals, so serialize/load (L7) stays plain-list s-expressions; no frozen-kernel
  reader change.

## Rejected (won't do)

- **Pushing structural formatting fully to DEVICE** — loses cross-host reuse and
  test coverage (see §3).
- **Forking a separate "command" object type** — a command is an ordinary KEC
  function plus metadata (the field-notes lesson); dispatch is data + `eval`.
- **Blocking LIB on the container ADR** — LIB is correct on cons/alists; §4 runs
  containers in parallel, not as a gate.

## Consequences

- The repo gains an **editor/REPL toolkit tier** above Core. Its identity widens
  from "just the language" to "the language + a host-agnostic authoring/editing
  toolkit" — consistent with the REPL and the desktop Emacs major mode it already
  ships. [boundary.md](../boundary.md) and the repo `CLAUDE.md` are updated to name
  the tier.
- The **`kec` CLI REPL becomes the reference host**: wiring the SEAM to a laptop
  REPL both delivers the strong standalone REPL and proves the SEAM is device-free.
- The KN-86 firmware **vendors the tier** and implements DEVICE (D1–D10) against
  the SEAM — no private-engine fork.
- **ADR-0003 follows immediately** to specify and land vectors + hash tables.
- The build follows the project discipline: every new form ships `kec test`
  conformance, the language reference / builtins page is updated, CI green on
  ubuntu + macos.

## Acceptance criteria

1. This ADR is merged; [boundary.md](../boundary.md) names the editor/REPL
   extended-library tier and points here.
2. ADR-0003 (containers) is opened and specifies the vector + hash design that
   §4 commits to.
3. The SEAM (S1–S9) is enumerated as the host contract; the S4 view-model
   boundary is recorded (§3).
4. The follow-on sprint builds the LIB modules as `provide`-gated tier files with
   conformance tests, the CLI REPL as the reference host, and the DEVICE work
   routed to `kn-86`.

## References

- [Field Notes: Writing GNU Emacs Extensions](../notes/field-notes-writing-gnu-emacs-extensions.md) — the language-vs-Emacs gap analysis the partition builds on.
- [ADR-0001: Base-Language Additions](ADR-0001-base-language-additions.md) — error recovery, utilities, bitwise, RNG; the container deferral this ADR amends.
- ADR-0003: Container Types — Vectors & Hash Tables (follows).
- [What's Here (boundary)](../boundary.md) — the standalone-vs-firmware boundary the LIB test restates.
