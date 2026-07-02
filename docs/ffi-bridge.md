---
title: FFI Bridge
description: How to make a C function callable from KEC Lisp — the bind seam, type marshalling, opaque handles, and arena discipline.
---

How to make a C function callable from KEC Lisp — what the KN-86 firmware (or
any program embedding KEC Lisp) does to add its own primitives. The working
examples are `host/host.c` and `runtime/kec.c`.

---

## 1. Registration — the `bind` seam

A C function becomes a KEC Lisp symbol through one GC-safe helper
(`host.h` / `host.c`):

```c
void kec_bind_fe(fe_Context *ctx, const char *name, fe_CFunc fn);
/* ≡ save GC stack → fe_set(ctx, fe_symbol(ctx,name), fe_cfunc(ctx,fn)) → restore */
```

```c
static fe_Object *lisp_beep(fe_Context *ctx, fe_Object *args) {
    fe_Number hz = fe_tonumber(ctx, fe_nextarg(ctx, &args));
    platform_beep((int)hz);
    return fe_bool(ctx, 0); /* nil — side-effecting primitive */
}

kec_bind_fe(kec_fe(S), "beep", lisp_beep);   /* now callable: (beep 440) */
```

- **Naming.** C `lisp_foo` → KEC Lisp `foo-bar` (kebab-case). The Lisp name is
  what callers use; the C name is internal.
- **Which context you bind into matters.** There's no global table of
  primitives — `kec_host_register` binds different sets per `kec_Profile`, and a
  host binds its own primitives the same way. A context can only call what was
  bound into it, which is how sandboxing works.
- **GC discipline is mandatory.** Interning a symbol and wrapping a cfunc each
  push a GC root; `kec_bind_fe` saves/restores around both. Reuse it.

## 2. Type marshalling (C ↔ KEC Lisp)

Arguments arrive as a pre-evaluated list; pull them with `fe_nextarg`.

| KEC Lisp type | C side |
|---|---|
| Bool | truthy / `nil`; `fe_bool(ctx, b)`, test `!fe_isnil(ctx,x)` |
| Number | `fe_tonumber` → `float` (single-precision; integers exact to ±2²⁴) |
| String | `fe_tostring(ctx, x, buf, size)` into a fixed buffer; `fe_string(ctx, cstr)` to return |
| Symbol / keyword | `fe_symbol(ctx, ":text")` — keywords are symbols |
| Opaque handle | `fe_ptr_typed(ctx, p, tag)` / `fe_toptr`; register a typed lifecycle (§3) |
| Unit | return `fe_bool(ctx, 0)` (nil) from side-effecting primitives |

## 3. Opaque handles (`FE_TPTR`)

A C struct handed to KEC Lisp crosses as a typed `FE_TPTR`. Use a stable tag
(normally the address of a private static object), register its lifecycle once
per context, and construct handles with the same tag:

```c
static const char SENSOR_HANDLE_TAG;

static void sensor_mark(fe_Context *ctx, void *ptr) {
    Sensor *s = ptr;
    if (s->callback) { fe_mark(ctx, s->callback); }
}

static void sensor_gc(fe_Context *ctx, void *ptr) {
    (void)ctx;
    sensor_release(ptr);
}

fe_register_ptr_type(ctx, &SENSOR_HANDLE_TAG, sensor_mark, sensor_gc);
fe_Object *handle = fe_ptr_typed(ctx, sensor, &SENSOR_HANDLE_TAG);
```

- Typed lifecycles compose: registering a firmware handle does not replace the
  vector/hash lifecycle. A callback receives only pointers created with its tag,
  so it never probes or dereferences another extension's raw pointer.
- `mark` roots nested Fe objects; `gc` releases C-side backing. Both are optional.
- **Construct two-phase when the backing must not leak.** `fe_ptr_typed` can
  raise out-of-memory (a `longjmp`), so a backing allocated before it is lost.
  Allocate the handle first with a `NULL` pointer, then attach the backing with
  `fe_set_ptr(ctx, handle, ptr)` — from that point the gc callback owns it.
  Callbacks must tolerate `NULL`. The KEC container constructors follow this
  pattern.
- **Narrow numbers through the shared checked helpers.** `kec_checked_int` /
  `kec_checked_byte` (host.h) pull the next argument as an exact integer (or
  byte), raising a catchable error on fractional, non-finite, or out-of-range
  values — a raw `(int)fe_tonumber(...)` cast is undefined behavior on NaN and
  out-of-range doubles. `kec_strlen_obj` / `kec_strdup_obj` stringify values at
  their exact printed length with no fixed buffer ceiling.
- Plain `fe_ptr` and the legacy `fe_handlers(ctx)->mark/gc` pair remain available
  for older single-owner embedders, but new code should use typed pointers.
- A handle is **invalid across an arena reset** (`fe_close`+`fe_open`). A
  primitive must never retain one across a reset, and Lisp must never stash one
  expecting it to survive.
- KEC Lisp never sees raw bytes; expose field access through accessor
  primitives, not pointer arithmetic.

## 4. Capability tiers

- A primitive belongs to a tier; the binder only binds it into contexts of that
  tier. This repo's worked example is `kec_Profile` (`FULL` adds `load`, file
  I/O, environment, `args`, and `exit` over `SANDBOX`).
- The KN-86 firmware layers its own tiers on top: an all-cart tier, a
  mission-context tier, a REPL read-only whitelist, and the privileged
  system-render tier — each just a different binding-set at context creation.

### Host-specific seams: the same Lisp name, a different C body

Some primitives are **terminal/host-specific** and deliberately do *not* live in
portable `host/host.c`. **`read-key` / `poll-key`** are the canonical example: the
`kec` CLI binds them (`cli/main.c`) over `read(2)` + `poll()` on stdin, which only
makes sense for a desktop TTY. The KN-86 firmware has no TTY — input is USB-HID /
evdev — so it registers the **same Lisp names** (`read-key`, `poll-key`) backed by
its own input path, through this same `bind` seam.

The portable artifact is therefore the **Lisp-facing contract**, not the C body:
a cart or editor module that calls `(poll-key 0.05)` runs unchanged on both the
laptop and the device. Bind such primitives from the *host* (the CLI, or the
firmware), never from the shared `host/host.c` — keep `host/host.c` for primitives
whose one implementation is correct everywhere (`sin`, `now`, string ops, …).

## 5. Error propagation

- **Every** C-side failure routes through `fe_error(ctx, msg)`. The runtime's
  installed handler unwinds to the nearest guard (REPL / script boundary /
  `(try …)`), never `exit()`.
- A primitive may not `exit()` and may not return after a half-applied
  mutation: either complete the side effect or `fe_error` *before* mutating.
- Degradation is not an error: a hardware-unavailable primitive should
  silent-no-op, not raise.

## 6. Lifetime & arena discipline

- Nothing arena-allocated survives `fe_close`+`fe_open`. Primitives compute
  against live state and return; they don't cache Fe objects across boundaries.
- Integrity-critical state (save data, ledgers, timing-critical cadence) stays
  C-side and is reached *through* primitives — carts never get a raw pointer
  into it.
- Portable host state is interpreter-local: error recovery, RNG sequence, and
  container allocation settings in one `kec_State` do not affect another.
- Configure container backing for one interpreter with
  `kec_set_container_allocator_for(S, alloc, free)`. Existing containers remember
  the allocator/free pair that created them, so changing the setting affects
  only future containers. `kec_set_container_allocator` remains a compatibility
  setter for the default used by subsequently opened contexts.

---

### Worked end-to-end

```c
#include "kec.h"

kec_State *S = kec_open(16u * 1024 * 1024, KEC_PROFILE_FULL);

/* extend the Stdlib with your own primitives */
kec_bind_fe(kec_fe(S), "beep", lisp_beep);
kec_bind_fe(kec_fe(S), "sensor-read", lisp_sensor_read);

/* now KEC Core + your device tier are both in scope */
kec_eval_string(S, "(dotimes (i 3) (beep (+ 440 (* i sensor-read))))", NULL);

kec_close(S);
```

That's the whole thing. The language comes from this repo as-is; your program
adds its own primitives with `kec_bind_fe`, and controls what each context can
do by choosing which ones to bind.
