---
title: Recent Language Additions Hardening Design
description: Design for hardening container integration, numeric contracts, reflection, readers, padding, and RNG state after the ADR-0001 and ADR-0003 language additions.
---

## Goal

Make the recent KEC Lisp additions safe for embedding and precise at their Lisp
boundaries without changing valid programs. The work covers the issues found in
the review of eval/reflection, ADR-0001 utilities, and ADR-0003 containers.

## Design

### Context-owned host state

Add a small tagged userdata registry to `fe_Context`. The KEC runtime uses it to
associate the active `kec_State` with the Fe context, replacing process-global
lookup for error recovery. Host state that belongs to an interpreter, including
the PRNG state and container allocator configuration, is held per context.

Container backing records the allocator's matching free callback at creation.
Changing the allocator for future containers therefore cannot cause an existing
container to be released through the wrong allocator.

### Composable foreign-pointer lifecycle

Extend the Fe handler surface with additive registration for multiple foreign
pointer lifecycle handlers. Each handler first identifies whether it owns a
pointer and, only when it does, marks or releases it. Container ownership is
tracked without dereferencing unowned foreign pointers. Existing single-handler
embedders remain source-compatible; the container layer uses the composable API.

### Precise language contracts

- Add true symbol-binding introspection so a symbol bound to `nil` remains bound;
  build `bound?`, `globals`, and `defvar` on that distinction.
- Centralize checked integer conversion for vector lengths/indices, bitwise
  operands and shifts, RNG seeds, and `rand-int`. Reject fractional, non-finite,
  or out-of-range numbers with a catchable error.
- Make `read-string` use the same length-aware conversion strategy as `read-all`.
- Define `pad-left` and `pad-right` as single-character-fill operations and
  reject empty or multi-character fill strings.
- Keep `eval` FULL-only and parsing available in both profiles.

### Compatibility

Valid existing calls retain their results. Behavior changes are limited to
previously ambiguous or unsafe inputs, which now raise explicit errors. Public
APIs added to Fe and KEC are additive.

## Testing

Use regression-first development. Lisp conformance tests cover nil-valued
bindings, long-form reading, padding validation, and integer validation. C tests
cover independent RNG sequences, allocator ownership after reconfiguration, and
coexistence between containers and an embedder's foreign-pointer lifecycle.

Run the full CTest suite, compiler-warning build, and Starlight documentation
build before publishing the draft pull request.

## Documentation

Update the language reference, built-ins overview, memory model, FFI bridge,
ADR-0001, ADR-0003, public header comments, and changelog. Remove the stale claim
that Lisp-level `eval` does not exist and explicitly document the new validation
and per-context ownership rules.
