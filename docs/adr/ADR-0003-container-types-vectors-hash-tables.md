---
title: "ADR-0003: Container Types — Vectors & Hash Tables"
description: Vectors and hash tables for KEC Lisp, implemented as typed FE_TPTR foreign objects with composable GC lifecycles, context-owned allocation, and scalar key equality.
---

- **Status:** Accepted
- **Date:** 2026-06-21
- **Deciders:** KEC Lisp maintainers
- **Supersedes / superseded by:** Closes the container item deferred by ADR-0001; committed to by ADR-0002 §4.
- **Amended:** 2026-06-22 by GWP-235 (typed pointer lifecycles and context-owned allocators)

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

The initial implementation used Fe's single `mark`/`gc` handler pair and probed
foreign backing for a magic word. GWP-235 hardened that seam after integration
review: Fe now supports small, composable **typed `FE_TPTR` lifecycles**. A
registered callback sees only pointers created with its stable tag, and typed
handlers coexist with the legacy raw-pointer handler pair. `gc` still runs at
sweep and `fe_close`, so backing is released deterministically.

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
- Each backing carries a container kind plus the allocator/free pair that
  created it. The Fe cell carries the registered container pointer-type id, so
  container code never dereferences an unowned firmware pointer.

### GC integration (composable typed lifecycle)

- **mark**: for each live container, `fe_mark()` every contained cell (vector
  elements; hash keys + values) so they survive the sweep.
- **gc**: when a container's `FE_TPTR` is collected, free its backing (and, for a
  hash, its slot array). Because `fe_close` sweeps everything, backings are freed
  at context teardown too — **no leak across the device's reset boundaries**.
- Firmware registers its own tags with `fe_register_ptr_type`; doing so cannot
  replace the container lifecycle. Plain `fe_ptr` remains supported through the
  legacy handler pair.
- Constructors keep element arguments **GC-rooted** across the `FE_TPTR`
  allocation (which may itself trigger a collection).

### Resolution of the deferred questions

1. **Backing memory.** Each interpreter has a container allocator, configured by
   `kec_set_container_allocator_for(S, alloc, free)` and defaulting to
   `malloc`/`free`. Every backing stores its matching callbacks, so changing the
   context affects future containers only and cannot cause cross-allocator frees.
   The older `kec_set_container_allocator` sets the default for subsequently
   opened contexts. A no-libc device installs its fixed-pool or bump allocator
   explicitly; caller ownership of the Fe arena alone does not imply this.
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
- Typed lifecycle registration composes container and firmware handles safely.
- The Fe kernel has small additive APIs for typed pointers and context userdata;
  existing raw-pointer handlers remain source-compatible.
- Container allocation is context-owned and explicit. The language reference,
  memory model, FFI guide, and `CHANGELOG` document the distinction between the
  fixed Fe arena and out-of-arena container backing.

## Acceptance criteria

1. `ctest` green on ubuntu + macos; new conformance suites
   `tests/core/vector.lsp` (35 checks), `tests/core/hash.lsp` (40 checks), and a
   GC-integration stress test `tests/core/container-gc.lsp` (held data survives
   forced collections; throwaway backings are reclaimed without corruption).
2. Vectors: bounds + type errors raise; `make-vector` fills with `init`; nested
   vectors work. Hash: number/symbol/string keys; string keys compare by content;
   overwrite keeps count; delete + reinsert (tombstone reuse); grow past initial
   capacity preserves all entries; unhashable key raises.
3. `c/arena` remains green; `c/host-state` verifies allocator ownership,
   multi-context isolation, and coexistence with a firmware-style pointer type.
4. Docs updated: the language reference Containers section + limits, and this ADR.

## References

- [ADR-0001: Base-Language Additions](ADR-0001-base-language-additions.md) — deferred containers (this ADR closes that).
- [ADR-0002: Editor/REPL Extended-Library Tier](ADR-0002-editor-repl-extended-library-tier.md) — §4 commits to building containers now.
- `host/containers.c`, `core/52-container.lsp`, `tests/core/{vector,hash,container-gc}.lsp`.
- `kernel/fe.h`/`fe.c` — `FE_TPTR`, typed-pointer registration, legacy
  `fe_Handlers`, `fe_mark`, and `fe_close`.
