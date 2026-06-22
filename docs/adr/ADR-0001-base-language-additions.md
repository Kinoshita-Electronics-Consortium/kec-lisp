---
title: "ADR-0001: Base-Language Additions for knEmacs & Cart Authoring"
description: Accepted base-language additions to KEC Lisp — error-recovery macros, small utilities, a string/char toolkit, bitwise operators, and a seedable RNG — derived from a source-verified Emacs-Lisp gap analysis. Containers (vectors, hash tables) are deferred to a follow-up.
---

- **Status:** Accepted
- **Date:** 2026-06-21
- **Deciders:** KEC Lisp maintainers
- **Supersedes / superseded by:** —
- **Amended:** 2026-06-22 by GWP-235 (strict integer contracts, nil-aware binding presence, context-local RNG, and one-character padding)

> **Hardening note.** The original sprint deliberately avoided kernel changes.
> GWP-235 later added small, additive kernel APIs after integration review showed
> that true bound-to-`nil` detection and composable foreign-pointer lifecycles
> could not be implemented safely through the original seams alone.

## Context

Two reading studies — the [GNU Emacs Manual](../notes/field-notes-emacs.md) and
[Writing GNU Emacs Extensions](../notes/field-notes-writing-gnu-emacs-extensions.md) —
were mined for what **KEC Lisp the language** must provide to host **knEmacs**
(the on-device editor, formerly nEmacs) and to serve cart authoring. The gap
analysis was then **verified against the actual source** (`kernel/`, `core/`,
`host/`, `runtime/kec.c`) rather than inferred. That verification matters because
it corrected several first-pass conclusions:

**Already present (no work needed):**

- Error *catching*: `try` + `raise` on a setjmp/longjmp guard stack
  (`runtime/kec.c`); errors are values — `(:error . message)` with
  `error?`/`error-message` (`core/35-error`).
- Feature registry: `provide` / `provided?` / `require` (`runtime/kec.c`).
- `gensym` (hygienic macros), `equal?` (structural equality), `let*` / `letrec` /
  `when` / `unless` / `case` / `dolist` / `dotimes` (`core/40-ctrl`),
  `eval` / `apply` / `macroexpand-1` / `read-string` / `read-all`
  (`runtime/kec.c`), reflection `globals` / `fn-params` / `bound?` (`host/`),
  `sort` with a comparator, `reduce` / `fold-*` (`core/50-hof`).

**Enabling kernel facts:**

- The kernel exposes a foreign-pointer type `FE_TPTR` **with a GC handler hook**
  (`fe_ptr`/`fe_toptr`, `handlers.gc`) — new aggregate types can be host objects
  without touching the frozen kernel.
- The kernel carries an **instruction budget** and a setjmp/longjmp error seam;
  numbers are single-precision `float` (exact ≤ ±2²⁴); `=`/`is` compare pairs by
  identity (`equal?` for structure); assignment is `set`; `nil` is the only false
  value and the empty list.

What remains splits cleanly by **cost**: pure-Lisp Core modules, simple host
number/string primitives, and (riskier) foreign-object containers. The
device discipline — arena allocation, **no `malloc` in the runtime**,
`GCSTACKSIZE` 256 — is the binding constraint that decides what is in scope now.

## Decision

Accept the following **for the immediate sprint**. All of it is either a Core
`.lsp` module or a simple host number/string primitive; **none touches the
frozen Fe kernel, and none introduces runtime `malloc`.**

### A. Error-recovery macros (Core, over the existing `try`/`raise`)

- `unwind-protect` — run a body, then run cleanup forms on **both** normal return
  and a raised error (re-raising afterward to preserve error semantics). This is
  what `save-excursion`/`save-restriction`-style wrappers need.
- `ignore-errors` — evaluate a body, yielding `nil` on any raised error.
- `condition-case` — catch a raised error and evaluate a handler (message-based;
  class dispatch is deferred — see below).

Reference shape: `(unwind-protect body . cleanup)` ⇒ catch with `try`, run
cleanup, re-raise if the result was an `error?`.

### B. Small utilities (Core)

- `prog1` — sequence; return the **first** subexpression's value.
- `defvar` — define a global **only if unbound** (`(if (bound? 'x) x (set 'x v))`),
  so user/config values, including `nil`, survive a later library load.
- `macroexpand` — full expansion (loop `macroexpand-1` to a fixpoint).

### C. String / char toolkit (Core, over existing host string primitives)

- Case: `string-upcase`, `string-downcase`, `char-upcase`, `char-downcase`.
- Layout for the fixed-cell text grid: `pad-left`, `pad-right`, `string-repeat`.
  Padding accepts exactly one fill character.
- Tests: `string-prefix?`, `string-suffix?`, `string-contains?`.

### D. Bitwise operators (host primitives)

- `bit-and`, `bit-or`, `bit-xor`, `bit-not`, `bit-shl`, `bit-shr`, operating on
  validated 32-bit integer-valued numbers. Fractional/non-finite/unsafe inputs
  raise instead of narrowing. Needed for PSG register
  packing, RGB565 color math, the Universal Deck State history bitfield, and flag
  sets — none of which the editor-focused study surfaced.

### E. Seedable RNG (host primitive)

- A deterministic seed control (e.g. `set-seed!` / `rng-seed`) so `rand` /
  `rand-int` become **reproducible per interpreter context**. The mission board generates contracts from
  cartridge templates *seeded by deck state*; reproducible procedural generation
  is load-bearing for that core loop, not a nicety.

## Deferred (accepted in principle; separate ADR + sprint)

- **Containers — vectors and hash tables.** High value (O(1) indexed grids/rings;
  O(1) keyed behavior/generation/save tables), and implementable as `FE_TPTR`
  host objects — but their **backing memory** (host `malloc` + a GC finalizer vs.
  an arena slab vs. a fixed pool) conflicts with the no-`malloc` arena invariant,
  and their **key-equality semantics** interact with KEC's identity-vs-structural
  rules. They warrant a dedicated design decision rather than being rushed into a
  "complete it" sprint.
- **Typed/structured errors** — enrich the error value to `(:error type . data)`
  so `condition-case` can dispatch by class; pairs with A when needed.
- **`autoload` / `eval-after-load`** — lazy load + post-load hooks (the registry,
  `provide`/`require`, already exists).
- **Regex subset + `regexp-quote`** — the deferred "expensive tier"; only literal
  `string-search` today.
- **`equal?` cycle-safety** — bounded/seen-set traversal so a cyclic structure
  cannot hang the device.
- **Exact integers beyond ±2²⁴**, optional float trig (`sin`/`cos`/`atan2`).

## Rejected (won't do)

- **Tail-call optimization in the frozen kernel.** Keep the deliberate
  iterative-Core discipline (`GCSTACKSIZE` 256); TCO is invasive and against the
  frozen-kernel stance.
- **A numeric tower**, or a namespace/module system beyond `provide`/`require`.

## Consequences

- knEmacs's command loop, REPL error survival, and `save-excursion`-class
  wrappers become expressible in Lisp (A).
- Cart authoring gains bit manipulation (D) and reproducible procedural
  generation (E); the text-grid + editor case/layout ergonomics improve (C).
- The original sprint made **no frozen-kernel changes and introduced no new
  runtime `malloc`**; the later GWP-235 hardening amendment is described above.
  Containers were explicitly queued rather than dropped.
- New Core modules wire into `CORE_SRCS` (load order) in `CMakeLists.txt` and into
  `mkembed`; host primitives register in `kec_host_register`. Every new form ships
  conformance tests, and the `docs/` language reference / builtins page is updated.

## Acceptance criteria

1. `ctest` green on ubuntu + macos; every new form has conformance tests
   (`tests/`), and `kec test` over the new files passes.
2. `unwind-protect` runs cleanup on normal return **and** on a raised error;
   `condition-case` returns the handler value on error and the body value
   otherwise; `ignore-errors` yields `nil` on error.
3. `bit-*` results match a reference table; `rand` under a fixed seed is
   reproducible across separate runs.
4. The string toolkit handles empty strings and pad/truncate boundaries.
5. Docs updated; the field-notes files corrected to reflect that `try`/`raise`
   and `provide`/`require` already exist (and that error-recovery is a Core-macro
   task, not a kernel change).

## References

- [Field Notes: Writing GNU Emacs Extensions](../notes/field-notes-writing-gnu-emacs-extensions.md)
- [Field Notes: GNU Emacs Manual](../notes/field-notes-emacs.md)
- Source seams verified 2026-06-21: `runtime/kec.c` (`try`/`raise`/`provide`/`require`),
  `core/35-error.lsp`, `core/40-ctrl.lsp`, `host/host.c`, `kernel/fe.h`/`fe.c`
  (`FE_TPTR`, instruction budget, error seam).
