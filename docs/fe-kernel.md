---
title: Fe Kernel — Internals
description: The rxi/fe interpreter vendored in KEC Lisp — object encoding, GC mechanics, known constraints, and KEC-specific additions to the kernel.
---

The KEC Lisp kernel is [rxi's Fe](https://github.com/rxi/fe) (version 1.0), vendored in `kernel/`. This page documents the design choices and constraints that affect anyone writing or embedding KEC Lisp, plus the KEC-specific changes applied on top of upstream Fe.

For the kernel's Lisp-visible forms, see [Built-ins](/kec-lisp/builtins/). For arena sizing, see [Memory Model](/kec-lisp/memory-model/).

---

## Design goals

Fe was built to fit on constrained hardware: a fixed-size memory region, no allocation after `fe_open`, portable ANSI C, and a source under 1000 lines. KEC vendors it for the same reason — the firmware supplies a static arena, and the interpreter never calls `malloc`.

---

## Object representation

Every Lisp value is a `fe_Object` — two machine words (`car` and `cdr`, each a union of a pointer, `float`, and `char`):

| Host | Object size |
|---|---|
| 64-bit | 16 bytes |
| 32-bit | 8 bytes |

**Pair vs. non-pair encoding:** the lowest bit of `car` is the pair flag.

| bit 0 of `car` | Meaning |
|---|---|
| `0` | `FE_TPAIR` — `car` and `cdr` are pointers to other objects |
| `1` | Non-pair — full type code stored in bits 2–7 of `car` |

Bit 1 of `car` is the **GC mark bit** (`GCMARKBIT = 0x2`). It is `0` while a program runs; both `collectgarbage()` and the cycle-detecting `fe_write` set it transiently and clear it before returning.

Non-pair types: `FE_TNIL`, `FE_TNUMBER`, `FE_TSYMBOL`, `FE_TSTRING`, `FE_TFUNC`, `FE_TMACRO`, `FE_TPRIM`, `FE_TCFUNC`, `FE_TPTR`, `FE_TFREE`.

**Little-endian only.** The tag byte layout assumes little-endian byte order. The interpreter will not work correctly on big-endian systems. This is a known upstream Fe constraint; KEC does not change it.

---

## Type details

### Numbers

`fe_Number` is `float` (single-precision IEEE 754). Integers are exact within **±2²⁴** (~16.7 million). The reader parses numbers with `strtod`; `fe_write` formats them with `%.7g`.

Substituting a different number type is possible but requires updating both `fe_read` and `fe_write`.

### Strings

A string is a linked chain of `FE_TSTRING` nodes. Each node stores `sizeof(fe_Object*) - 1` bytes in the unused portion of `car`:

| Host | Bytes per node |
|---|---|
| 64-bit | 7 |
| 32-bit | 3 |

`cdr` points to the next node, or `nil` at the end. **Strings are null-terminated and not binary-safe** — a null byte inside a string truncates it. This is a known upstream Fe constraint.

### Symbols

Symbols are **interned**: `fe_symbol(ctx, "foo")` always returns the same object. The global binding lives in the symbol's `cdr` (a cons cell containing the name string). Every `fe_symbol` call walks `ctx->symlist` to check for an existing intern.

KEC uses one otherwise-unused byte in a symbol's `car` word to record whether a
global binding has been established. This distinguishes an unbound symbol from
a symbol deliberately bound to `nil`; `fe_bound`, `bound?`, `globals`, and
`defvar` use that distinction.

That distinction is not enforced at *evaluation* time, though: `eval()`
(`kernel/fe.c:830`) reads a symbol's binding with `getbound`/`cdr` regardless of
the presence bit, so referencing a symbol that was never bound evaluates to
`nil` rather than raising an "unbound variable" error — the same result as a
symbol deliberately bound to `nil`. `bound?` is the only way to tell the two
apart at the Lisp level; see
[Evaluation](/kec-lisp/language/#evaluation) and
[Limits And Portability](/kec-lisp/language/#limits-and-portability).

The reader reads tokens into a 64-byte buffer (`char buf[64]`). **Symbol names longer than 63 bytes** raise `"symbol too long"`.

### Environments

Environments are association lists: `((sym . val) (sym . val) …)`. Globally bound values are stored directly in the symbol object's binding cell, not in a hash table.

---

## Garbage collector

A **mark-and-sweep collector** over a freelist:

1. At `fe_open` all arena slots are linked into the freelist.
2. When an object is needed it is popped from the freelist and pushed to the GC root stack.
3. When the freelist is empty, a full mark-sweep runs — roots are marked, unreachable objects are swept back onto the freelist.
4. If the freelist is still empty after a full collection, `fe_error("out of memory")` fires.

### GC root stack

`ctx->gcstack[GCSTACKSIZE]` protects in-flight objects from collection. The size is compile-time configurable:

| Build | `GCSTACKSIZE` |
|---|---|
| Default / device | **256** |
| KEC desktop build | **8192** |

Overflow calls `fe_error("gc stack overflow")`. Because the stack is bounded, [Core](/kec-lisp/language/#standard-library-core) writes its list/sequence functions iteratively, and the [Language Reference](/kec-lisp/language/#quick-lookup) recommends `while` / `fold-left` for deep work over your own data.

### `car` recursion in the mark phase

`fe_mark` recurses on `car` of pairs but iterates on `cdr` (via `goto`). A structure with many levels of nesting in the **`car` dimension** — for example `((((…))))` — may overflow the **C call stack** during GC mark. `cdr` chains of any depth are safe.

In practice this affects hand-constructed deeply-nested data more than ordinary Lisp programs; it is rarely triggered.

### Typed foreign pointers

`fe_register_ptr_type` registers up to eight composable `FE_TPTR` lifecycle
types per context. `fe_ptr_typed` stores the type id in an unused byte of the
object's `car` word. Mark/sweep dispatches only to that type's callbacks, so one
extension cannot replace another's lifecycle or inspect an unowned raw pointer.
Untyped `fe_ptr` values continue to use the legacy `fe_Handlers.mark/gc` pair.

`fe_set_ptr` replaces an existing `FE_TPTR`'s pointer, enabling **leak-free
two-phase construction**: allocate the collectable pointer object first with a
`NULL` pointer — the only step that can raise out-of-memory — then attach the
foreign backing, which is from that point owned by the type's gc callback.
Lifecycle callbacks must tolerate a `NULL` pointer. The KEC container
constructors are built on this pattern; before it existed, an out-of-memory
`longjmp` out of `fe_ptr_typed` leaked the not-yet-owned backing.

---

## Macro expansion

Macros expand **in-place**: `eval` overwrites the call-site `fe_Object` with the expansion (`*obj = *expansion`). The macro body runs once per call site; subsequent evaluations at that site execute the already-expanded form directly.

Practical consequence: a macro called inside a loop expands on the first iteration and the loop then runs the expanded code with no further macro overhead. The original source list at the call site is destroyed by the expansion.

`macroexpand-1` uses the same macro closure representation but does **not**
mutate the form it receives. It expands only one symbolic macro call and returns
non-macro forms unchanged.

---

## Known constraints (inherited from upstream Fe)

| Constraint | Impact |
|---|---|
| **No tail-call optimization** | Each recursive call allocates a C stack frame. For iteration over long lists use `while` or Core's iterative higher-order functions. |
| **`car` recursion in GC mark** | Deeply nested CAR chains can overflow the C stack during collection. CDR chains (ordinary lists) are safe at any length. |
| **Little-endian only** | The type-tag byte layout is not portable to big-endian systems. |
| **Strings null-terminated** | Embedded null bytes truncate a string. Not binary-safe. |
| **Symbol name limit** | 63 bytes maximum (from the reader's 64-byte token buffer). |

---

## KEC additions to the upstream kernel

Changes applied on top of rxi/fe 1.0, in `kernel/fe.c` and `kernel/fe.h`:

| Change | Reference | Detail |
|---|---|---|
| **`set` for assignment** | CHANGELOG 0.1.0 | The assignment primitive is named `set` rather than `=`, freeing `=` for Core's equality. |
| **Top-level `let` binds globally** | CHANGELOG 0.1.0 | Upstream `let` at the top level was a silent no-op (no enclosing body). KEC patches it to bind globally — equivalent to `set` when there is no enclosing scope. |
| **`GCSTACKSIZE` configurable** | CHANGELOG 0.1.0 | Added `#ifndef GCSTACKSIZE` guard; the desktop build sets 8192 via `CMakeLists.txt`. |
| **Quasiquote reader** | CHANGELOG Unreleased | `` ` `` reads as `quasiquote`, `,` as `unquote`, `,@` as `unquote-splicing`. Not present in upstream Fe. |
| **Circular-safe `fe_write`** | CHANGELOG 0.1.0 / upstream PR #22 | GCMARKBIT is borrowed during traversal to detect cycles; prints `...` in their place, then clears the marks. The upstream code looped or stack-overflowed on circular structures. |
| **`\r` comment termination** | CHANGELOG 0.1.0 / upstream PR #25 | Comment scanner stops on `\r` as well as `\n`, fixing Windows `\r\n` line endings. |
| **`fe_savegc` order in `fe_open`** | CHANGELOG 0.1.0 / upstream PR #25 | `fe_savegc` now precedes the `t` symbol allocation so a GC triggered during that allocation cannot collect `t`. |
| **Instruction budget API** | GWP-248 | `fe_set_instr_budget` / `fe_get_instr_count` / `fe_reset_instr_count` — sandbox evaluation time limit, off by default (`budget == 0`). |
| **Arena introspection API** | GWP-233 | `fe_arena_stats` / `fe_object_size` / `fe_min_arena_bytes` — inspect live/total object counts and minimum safe arena size. |
| **Symbol-list accessor** | CHANGELOG Unreleased | `fe_symbols` — read-only view of the interned-symbol list, for host introspection (the `bound?` / `globals` primitives). Returns live internal structure; the host builds a fresh list from it and never hands it to Lisp. |
| **Closure-params accessor** | CHANGELOG Unreleased | `fe_fn_params` — parameter list of a `FE_TFUNC`/`FE_TMACRO` (cadr of its `(env params . body)`), for the `fn-params` primitive; `nil` for built-ins. Returns live internal structure; the host copies it before handing it to Lisp. |
| **Binding-presence accessor** | GWP-235 | `fe_bound` plus a symbol binding-presence bit distinguish unbound from deliberately bound-to-`nil`; used by `bound?`, `globals`, and `defvar`. |
| **Tagged context userdata** | GWP-235 | `fe_set_userdata` / `fe_userdata` provide four fixed, non-owning tagged entries for runtime and portable-host state without numeric slot collisions. |
| **Composable typed pointers** | GWP-235 | `fe_register_ptr_type` / `fe_ptr_typed` / `fe_ptr_is_type` dispatch foreign-pointer lifecycle callbacks by registered tag while retaining legacy raw-pointer handlers. |
| **Typed-pointer setter** | GWP-584 | `fe_set_ptr` replaces an `FE_TPTR`'s pointer, enabling leak-free two-phase foreign construction (pointer object first, backing attached after). |
| **Standard-global symbol protection** | GWP-584 | `fe_protect_symbol` / `fe_symbol_protected` / `fe_set_symbol_protection_enabled` plus a `SYM_PROTECTED` bit freeze standard globals against rebinding via `set` and top-level `let`; applied to the primitives in `fe_open`, extended by `kec_protect_standard_globals`. |

---

## Where upstream Fe docs diverge from this kernel

The [upstream rxi/fe documentation](https://github.com/rxi/fe) is accurate for this kernel **except**:

| Upstream docs say | KEC kernel does |
|---|---|
| Assignment form is `(= sym val)` | Assignment form is `(set sym val)` |
| Macro examples use `(= …)` | Write `(set …)` instead |
| `fe_write` on circular structures → crash or infinite loop | Fixed — cycle detection via GCMARKBIT |
| Comments end on `\n` only | Also terminate on `\r` |
| Quasiquote not mentioned | `` ` `` / `,` / `,@` are in the reader |

Everything else in the upstream docs — object types, `is` equality semantics,
the environment model, the freelist GC, and the known-issues list — describes
this kernel accurately. KEC additionally supports composable typed-pointer
handlers as documented above.
