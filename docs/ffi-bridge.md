# The FFI Bridge Contract

How to expose a C library as **KEC Stdlib** — the seam a downstream host (the
KN-86 firmware, or your own embedding) uses to make C callable from KEC Lisp.
This is the implementation-grounded form of standard §6; the live seam is
`host/host.c` (the portable stdlib) and `runtime/kec.c` (`load`, `try`).

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
  the contract; the C name is private.
- **Tier = which context you bind into.** There is no global table of all
  primitives. `kec_host_register` binds different sets per `kec_Profile`; a
  downstream host binds its device tier the same way. **The binding-set *is*
  the sandbox** — a context cannot reach a primitive that was never bound into
  it (standard §2.1, §6.4).
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
  primitives, never pointer arithmetic. The FFI boundary is the tamper
  boundary.

## 4. Capability tiers

- A primitive belongs to a tier; the binder only binds it into contexts of that
  tier. This repo's worked example is `kec_Profile` (`FULL` adds
  `load`/`slurp`/`args`/`exit` over `SANDBOX`).
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

That is the whole integration surface. KEC Core and the language semantics come
from this repository unchanged; your host supplies its primitives through
`kec_bind_fe` and its sandbox through which primitives it binds where.
