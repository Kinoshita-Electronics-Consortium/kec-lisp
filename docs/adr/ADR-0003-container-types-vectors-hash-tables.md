---
title: "ADR-0003: Container Types — Vectors & Hash Tables"
description: Vectors and hash tables for KEC Lisp, implemented as FE_TPTR foreign objects with GC-integrated backing, a settable allocator that defaults to malloc/free (resolving the no-malloc concern), and key equality that mirrors the language's number-by-value / symbol-by-identity / string-by-content rules. Closes ADR-0001's container deferral.
---

- **Status:** Accepted
- **Date:** 2026-06-21
- **Deciders:** KEC Lisp maintainers
- **Supersedes / superseded by:** Closes the container item deferred by ADR-0001; committed to by ADR-0002 §4.

## Context

[ADR-0001](ADR-0001-base-language-additions.md) accepted vectors and hash tables
**in principle** but deferred them, naming two design questions:

1. **Backing memory** — host `malloc` + a GC finalizer vs. an arena slab vs. a
   fixed pool — conflicts with the runtime's **no-`malloc`** arena invariant
   (`kec_open_with_arena`, the device entry point).
2. **Key equality** — hash-table keys interact with KEC's identity-vs-structural
   equality split (`=`/`is` compare pairs by identity; `equal?` is structural).

[ADR-0002](ADR-0002-editor-repl-extended-library-tier.md) §4 then committed to
building containers **now** (not on the editor/REPL critical path, but in parallel)
because the device-targeted editor modules want O(1) structures from the start:
the REPL **history ring**, the cell **grid**, **undo**, and the ranker's
**vocabulary index**, plus de-risking the ranker's per-render latency under the
tree-walking interpreter.

The enabling kernel facts (verified in `kernel/fe.c`/`fe.h`): the frozen Fe kernel
exposes a foreign-pointer type **`FE_TPTR`** (`fe_ptr`/`fe_toptr`) and a single
pair of **`mark`/`gc` handler hooks** (`fe_Handlers`). The `mark` handler is
invoked for every live `FE_TPTR` during the mark phase; the `gc` handler is
invoked when one is swept — **including at `fe_close`**, which clears the roots
and sweeps everything. So a new aggregate type can be a host object with its
elements kept alive and its backing freed deterministically, **with no kernel
change**.

## Decision

Implement **vectors** and **hash tables** as `FE_TPTR` foreign objects in a new
`host/containers.c`, registered into every profile by `kec_host_register`
(they are pure data structures — safe in `SANDBOX`).

### Representation

- The `FE_TPTR` cell holds a pointer (in its `cdr`) to a C **backing struct** that
  lives **outside** the Fe arena. Element / key / value **cells are ordinary Fe
  objects in the arena**.
- A **vector** is one allocation: a header + an inline `fe_Object*` array
  (fixed length; O(1) `vector-ref`/`vector-set!`).
- A **hash table** is a header + a separately-allocated **open-addressing** slot
  array (linear probing, tombstone deletes, grow-and-rehash at load factor 0.75).
- Each backing carries a **magic** word + a **kind** tag, so the shared handlers
  dispatch vector vs. hash and a foreign (non-container) `FE_TPTR` is left
  untouched.

### GC integration (one handler pair on the context)

- **mark**: for each live container, `fe_mark()` every contained cell (vector
  elements; hash keys + values) so they survive the sweep.
- **gc**: when a container's `FE_TPTR` is collected, free its backing (and, for a
  hash, its slot array). Because `fe_close` sweeps everything, backings are freed
  at context teardown too — **no leak across the device's reset boundaries**.
- Constructors keep element arguments **GC-rooted** across the `FE_TPTR`
  allocation (which may itself trigger a collection).

### Resolution of the deferred questions

1. **Backing memory.** Container backing goes through a **settable allocator**
   (`kec_set_container_allocator`, in `host.h`) defaulting to `malloc`/`free`. The
   standalone language and desktop CLI use the default (allocation is explicit and
   program-bounded, not a hot-path implicit churn — the runtime already mallocs a
   transient buffer in `read-all`). The **no-`malloc` device path installs an
   arena-bump allocator** here, so libc `malloc` is never forced on the device.
   This is the deliberate resolution of ADR-0001's first concern.
2. **Key equality.** Hash keys mirror the language's own equality rules and are
   restricted to the **safely-comparable** scalar types:
   - **numbers** — by value (`-0.0` folded to `+0.0`);
   - **symbols** — by identity (Fe interns symbols, so identity *is* name
     equality — fast and exact);
   - **strings** — by content (FNV-1a hash + `strcmp` over the printed bytes).
   - **pairs and other aggregates are not hashable** — they raise a clear error
     rather than silently keying by identity or risking non-termination on a
     cyclic structure. This sidesteps ADR-0001's second concern instead of
     entangling the table with `equal?`'s structural traversal.

### API surface

Primitives (`host/containers.c`): `make-vector`, `vector`, `vector-ref`,
`vector-set!`, `vector-length`, `vector?`; `make-hash-table`, `hash-set!`,
`hash-ref`, `hash-has?`, `hash-del!`, `hash-count`, `hash-keys`, `hash-table?`.

Core conveniences (`core/52-container.lsp`, iterative like the rest of Core):
`vector->list`, `list->vector`, `vector-fill!`, `vector-copy`, `vector-map`,
`vector-for-each`; `hash-values`, `hash->alist`, `alist->hash`, `hash-for-each`.

## Deferred / out of scope

- **Reader syntax** — vectors are runtime objects, not `[...]` literals. No frozen
  kernel reader change; serialize/load of editor buffers (ADR-0002 L7) stays
  plain-list s-expressions.
- **Structural `equal?` over vectors** — vectors compare by identity for now; a
  structural vector case in `core/20-cmp` can follow if needed (use `vector->list`
  + `equal?` meanwhile).
- **Long string keys** — string keys compare/hash over their first **1024 bytes**
  (symbols/numbers are exact); editor/REPL keys are short tokens, so this is a
  documented limit, not a practical one.

## Consequences

- KEC Lisp gains O(1) indexed and keyed structures — the substrate for the editor
  history ring, cell grid, undo, and ranker vocabulary index.
- **Containers compare by identity** (they are `:ptr` objects); documented, with
  the `vector->list`/`hash->alist` + `equal?` idiom for content comparison.
- **One `mark`/`gc` handler pair per context.** A downstream host (the firmware)
  that adds its own `FE_TPTR` types must compose with these magic-guarded handlers
  (chain, or extend the dispatch) — noted for the firmware integration.
- No frozen-kernel change; the no-`malloc` invariant is preserved via the
  allocator seam. The language reference and `CHANGELOG` are updated.

## Acceptance criteria

1. `ctest` green on ubuntu + macos; new conformance suites
   `tests/core/vector.lsp` (35 checks), `tests/core/hash.lsp` (40 checks), and a
   GC-integration stress test `tests/core/container-gc.lsp` (held data survives
   forced collections; throwaway backings are reclaimed without corruption).
2. Vectors: bounds + type errors raise; `make-vector` fills with `init`; nested
   vectors work. Hash: number/symbol/string keys; string keys compare by content;
   overwrite keeps count; delete + reinsert (tombstone reuse); grow past initial
   capacity preserves all entries; unhashable key raises.
3. The no-`malloc` `c/arena` C test still passes (containers default to `malloc`
   but the arena seam is unaffected).
4. Docs updated: the language reference Containers section + limits, and this ADR.

## References

- [ADR-0001: Base-Language Additions](ADR-0001-base-language-additions.md) — deferred containers (this ADR closes that).
- [ADR-0002: Editor/REPL Extended-Library Tier](ADR-0002-editor-repl-extended-library-tier.md) — §4 commits to building containers now.
- `host/containers.c`, `core/52-container.lsp`, `tests/core/{vector,hash,container-gc}.lsp`.
- `kernel/fe.h`/`fe.c` — `FE_TPTR`, `fe_ptr`/`fe_toptr`, `fe_Handlers` (`mark`/`gc`), `fe_mark`, `fe_close`.
