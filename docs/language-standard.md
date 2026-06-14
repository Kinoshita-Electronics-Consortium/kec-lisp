---
title: Language Standard
description: The prescriptive layer model for KEC Lisp — Fe Kernel, KEC Core, and host primitives — and where the KN-86 firmware's device layers sit on top.
---

This is the prescriptive standard for **KEC Lisp** as the standalone language
this repo ships: its identity, its layer model, and the contracts each layer
must honor. The [Language Reference](/kec-lisp/language/) and
[Built-ins](/kec-lisp/builtins/) pages are the descriptive companions — they
enumerate the forms; this page fixes the *structure* the forms live in.

> Adapted from the KN-86 project's internal KEC Lisp standard, de-coupled from
> the device. Where that document describes a four-layer model ending in a
> runtime FFI surface (NoshAPI) and a cartridge grammar, those top layers are
> **firmware**, not part of the standalone language — see
> [§5](#5-relationship-to-the-kn-86-firmware).

---

## 1. Why a named language

KEC Lisp is not "raw Fe." It is [Fe](https://github.com/rxi/fe) — an ~800-LOC
vendored kernel — *plus* a standard library of common functions and macros
*plus* a set of portable C primitives. Naming that whole composed surface **KEC
Lisp** (Kinoshita Electronics Consortium Lisp) makes it a real, versioned,
documentable artifact: a language we own and specify, not a thin veneer over an
off-the-shelf interpreter. The kernel is the machine; KEC Lisp is the vocabulary
you actually write in.

## 2. The layers

KEC Lisp is composed of three layers in this repo, with a fourth that belongs to
the firmware. Each layer depends only on the ones below it.

| Layer | What it is | State in this repo | Spec home |
|---|---|---|---|
| **Fe Kernel** | The 26 vendored Fe primitives + reader + evaluator + arena/GC. The machine. | Vendored `rxi/fe` 1.0 with the changes in §3. | [Built-ins](/kec-lisp/builtins/) |
| **KEC Core** | The prelude: pure-KEC-Lisp functions + macros loaded into every context — `map filter fold-left cond when defn …`. The part that turns Fe into a usable language. | **Ships.** Authored in `core/*.lsp`, baked into the `kec` binary at build time. | [Language Reference §3](/kec-lisp/language/#3-the-standard-library-core) |
| **Host primitives** | Portable C exposed to KEC Lisp — `type-of`, math, string ops, I/O, a few system calls. Tiered by [profile](/kec-lisp/ffi-bridge/#4-capability-tiers). | **Ships.** `host/host.c`, registered via `kec_host_register`. | [Language Reference §4](/kec-lisp/language/#4-c-primitives-host) |
| *Device primitives + cart grammar* | *The KN-86 runtime FFI (graphics, audio, save, missions, CIPHER) and the `defcell`/`defmission` authoring DSL.* | *Not here — lives in the firmware.* | [§5](#5-relationship-to-the-kn-86-firmware) |

- **"KEC Lisp the language"** = Fe Kernel + KEC Core.
- **"KEC Lisp as this repo ships it"** = + host primitives.
- The firmware adds its device layer on top through the same FFI seam.

The shared principle across all of it: **capability is the binding-set.** Which
primitives a context is created with *is* what it is allowed to do — enforced at
context creation, not by per-call checks.

## 3. Layer 0 — the Fe Kernel

The 26 compiled-in primitives are:

```
let  set  if  fn  mac  while  quote  and  or  do
cons  car  cdr  setcar  setcdr  list  not  is  atom  print
<  <=  +  -  *  /
```

Full reference: [Built-ins](/kec-lisp/builtins/). Single-precision-float numbers;
immutable strings; `nil` is false and the empty list; no booleans, vectors, hash
tables, keyword args, TCO, or `eval`-from-Lisp.

The kernel is rxi's [Fe](https://github.com/rxi/fe), vendored. It carries these
changes from upstream Fe:

- **Assignment is `set`, not `=`** — freeing `=` to mean equality (supplied by Core).
- **Top-level `let` binds globally** instead of being a silent no-op.
- **`GCSTACKSIZE` is compile-time configurable** (default 256 for the device,
  raised to 8192 on the desktop build).

All deltas are recorded in the [CHANGELOG](https://github.com/Kinoshita-Electronics-Consortium/kec-lisp/blob/main/CHANGELOG.md).

## 4. Layers 1 & 2 — Core and host primitives

**KEC Core** is the prelude that makes Fe a usable language: definition macros
(`defn`, `defmacro`, `define`), list/sequence functions, comparison (`=`, `==`,
`/=`, `>`, `>=`, …), type predicates, control macros (`cond`, `case`, `when`,
`dotimes`, …), higher-order functions, and string/format helpers. It is authored
in KEC Lisp, loaded into every context before user code runs, and its
list/sequence functions are written **iteratively** so they don't exhaust the
bounded GC-root stack. The canonical enumeration is the
[Language Reference §3](/kec-lisp/language/#3-the-standard-library-core); a
conforming implementation provides those forms with those semantics.

**Host primitives** are the small set of C functions that need only the C library
— `type-of` (the one type-introspection primitive Core's `number?`/`string?`/…
predicates require), math, string ops, I/O, and a few system calls. They are
bound per [profile](/kec-lisp/ffi-bridge/#4-capability-tiers): `SANDBOX` is the
portable core; `FULL` adds `load` / `slurp` / `args` / `exit`. The enumeration is
the [Language Reference §4](/kec-lisp/language/#4-c-primitives-host).

## 5. The FFI bridge contract

The seam between C and KEC Lisp is one GC-safe registration helper,
`kec_bind_fe(ctx, "name", fn)`, plus a small set of marshalling and lifetime
rules. The full contract — registration, the C↔Lisp type table, opaque handles,
capability tiering, error propagation, and arena discipline — is specified on the
[FFI Bridge](/kec-lisp/ffi-bridge/) page. Write a C subsystem against that
contract and it becomes callable KEC Lisp with no other change. This is exactly
how both this repo's host primitives and the firmware's device primitives are
added; they differ only in *which* context they bind into.

## 6. Versioning & stability

| Layer | Versioning rule |
|---|---|
| **Fe Kernel** | Based on `rxi/fe` 1.0; the changes from upstream are listed in §3 and the CHANGELOG. |
| **KEC Core** | Versioned as a unit. Additions are backwards-compatible; no removal without a major bump. Ships as KEC Lisp source baked into the binary. |
| **Host primitives** | Additions are backwards-compatible; the profile a primitive belongs to is part of its contract. |

## 7. Relationship to the KN-86 firmware

The KN-86 firmware vendors this repo as a library and adds its **device layer**
on top — the runtime FFI for graphics, audio, save state, missions, and the
CIPHER voice, plus the cartridge authoring grammar (`defcell`, `defmission`, …)
and the per-context permission tiers that gate them. None of that runs without
the device, and none of it is part of the standalone language standard. It is
added through the same [FFI bridge](/kec-lisp/ffi-bridge/) contract described
here, and documented separately in the device's own documentation. For the
in/out boundary, see [What's Here](/kec-lisp/boundary/).
