---
title: Memory Model
description: KEC Lisp runs against a fixed-size arena per context — how arenas are sized, who owns them, the no-malloc entry point, and what bounds recursion.
---

KEC Lisp runs against a **fixed-size Fe object arena per interpreter context**.
You hand the runtime a block of memory once, and all Fe objects live inside it
until the context is torn down. Container backing arrays are explicitly managed
outside that arena through a configurable per-context allocator, described below.

## One state, one context, one arena

The embedding API (`runtime/kec.h`) hands you a `kec_State`, and each
`kec_State` owns exactly one Fe context backed by one arena:

```c
kec_State *S = kec_open(16u * 1024 * 1024, KEC_PROFILE_FULL);
/* ... eval against S ... */
kec_close(S);
```

- `kec_open(bytes, profile)` `malloc`s an arena of `bytes` and loads Core into
  it. The desktop CLI uses **16 MB** (`ARENA_BYTES` in `cli/main.c`).
- `kec_close(S)` tears the context down and frees what `kec_open` allocated.

Fe is a mark-sweep collector over a **fixed-size object pool** carved from that
arena. The GC runs *inside* a context: it reclaims dead objects but does not grow
the pool. Exhausting the arena is a runtime error (see
[Errors](/kec-lisp/language/#errors)).

Vectors and hash tables are the deliberate exception to "all storage is in the
Fe arena": their `FE_TPTR` cells live in the arena, while their backing arrays
use the context's container allocator. The default is `malloc`/`free`; a device
can install a fixed-pool or bump allocator with
`kec_set_container_allocator_for`. Every backing remembers its matching free
callback, and typed foreign-pointer GC releases it at sweep or `fe_close`.
Construction is two-phase (the `FE_TPTR` cell is allocated *before* the backing,
then attached with `fe_set_ptr`), so an out-of-memory error from an exhausted
Fe arena can never strand a backing allocation — the C host-state tests churn
constructors at arena saturation and assert the allocator's alloc/free counts
balance.

## The no-malloc entry point

To run without `malloc`ing the arena — for example on the KN-86 device — supply
your own buffer:

```c
static unsigned char arena[256 * 1024];
kec_State *S = kec_open_with_arena(arena, sizeof arena, KEC_PROFILE_SANDBOX);
if (!S) { /* buffer too small to even load Core */ }
```

- `kec_open_with_arena(buf, size, profile)` does **no** `malloc` of the arena.
  The buffer is yours; `kec_close` never frees it.
- It returns `NULL` cleanly if `size` is too small to load Core — it never
  `exit()`s or partially initializes. `kec_open` is just this with a `malloc`ed
  buffer.

This seam is exercised by the C-level arena tests (`tests/c/test_arena.c`,
ctest name `c/arena`), which cover sizing and the undersized-buffer path that the
`.lsp` suite can't reach.

`kec_open_with_arena` means the **Fe object arena** is caller-owned; it does not
by itself select a no-heap container allocator. Firmware that prohibits libc
allocation must configure the container allocator explicitly before creating
vectors or hash tables. The C host-state tests verify allocator ownership and
cross-context isolation.

## Lifetime

The arena exists from `kec_open*` until `kec_close`; nothing in it survives the
teardown. C code must not retain a pointer into Fe-managed memory across a reset
(`fe_close`+`fe_open`) — such handles are invalidated by it. State you need to
keep lives in your C program, reached through primitives.

> **Firmware uses finer boundaries.** The KN-86 firmware adds its own reset
> boundaries on top of this one — fresh contexts at cartridge load,
> mission-instance start/end, and REPL/editor sessions, each with its own arena
> budget. Those boundaries are a firmware concern, not part of the standalone
> language; see the [FFI Bridge](/kec-lisp/ffi-bridge/) for the lifetime rules
> across a reset.

## What bounds recursion

| Compartment | Notes |
|---|---|
| Object pool (the arena) | Fixed at `kec_open*` time. All pairs, strings, closures live here. |
| GC root stack | `GCSTACKSIZE`, **compile-time configurable** — default **256** (sized for the device), raised to **8192** on the desktop build (`target_compile_definitions` in `CMakeLists.txt`). |
| Call depth | No tail-call optimization. Deep recursion consumes the GC root stack and the C stack. |

Because the GC root stack is bounded, the Core library's list/sequence functions
are written **iteratively** — `while` rather than deep recursion — so a long list
won't exhaust the stack. For your own deep work, prefer `while` or `fold-left`
over hand-rolled recursion. Numbers are single-precision floats, so counters and
indices are exact only within ±2²⁴.

For the GC implementation — mark-sweep mechanics, the CAR-recursion constraint,
and the full list of inherited constraints — see [Fe Kernel — Internals](/kec-lisp/fe-kernel/#garbage-collector).

## Profiles control capability, not size

A context's [profile](/kec-lisp/ffi-bridge/#4-capability-tiers) (`KEC_PROFILE_FULL`
vs `KEC_PROFILE_SANDBOX`) decides *which primitives* are bound into it — e.g.
`FULL` adds file and system primitives. It does not change the arena model:
every profile is one context, one arena, the same reset semantics.
