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
| Opaque handle | `fe_ptr(ctx, p)` / `fe_toptr`; supply `mark`/`gc` handlers (§3) |
| Unit | return `fe_bool(ctx, 0)` (nil) from side-effecting primitives |

## 3. Opaque handles (`FE_TPTR`)

A C struct handed to KEC Lisp crosses as `FE_TPTR`:

- Supply `mark` (root nested Fe objects) and `gc` (release) handlers via
  `fe_handlers(ctx)` so the handle survives mark-sweep.
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
