---
title: Language Standard
description: How KEC Lisp is layered — the Fe kernel, KEC Core, and host primitives — and where the KN-86 firmware's device layer sits on top.
---

KEC Lisp is built in layers. This page describes them and links to the reference
pages that enumerate each layer's forms.

## The layers

| Layer | What it is | In this repo | Reference |
|---|---|---|---|
| **Fe Kernel** | 26 compiled-in primitives + reader + evaluator + arena/GC. | Vendored `rxi/fe` 1.0 with the changes in [The Fe kernel](#the-fe-kernel) below. | [Built-ins](/kec-lisp/builtins/) |
| **KEC Core** | The standard library — `map`, `filter`, `fold-left`, `cond`, `when`, `defn`, … — written in KEC Lisp, loaded into every context before user code runs. | `core/*.lsp`, baked into the `kec` binary at build time. | [Language Reference §3](/kec-lisp/language/#3-the-standard-library-core) |
| **Host primitives** | Portable C exposed to KEC Lisp — `type-of`, math, string ops, I/O, a few system calls. | `host/host.c`, registered via `kec_host_register`. | [Language Reference §4](/kec-lisp/language/#4-c-primitives-host) |
| **Device primitives + cart grammar** | The KN-86 runtime FFI (graphics, audio, save, missions, CIPHER) and the `defcell`/`defmission` macros. | Not in this repo — in the firmware. | [The KN-86 firmware](#the-kn-86-firmware) |

Which primitives a context is created with determines what it can call; see the
[FFI Bridge](/kec-lisp/ffi-bridge/).

## The Fe kernel

The 26 compiled-in primitives:

```
let  set  if  fn  mac  while  quote  and  or  do
cons  car  cdr  setcar  setcdr  list  not  is  atom  print
<  <=  +  -  *  /
```

Full reference: [Built-ins](/kec-lisp/builtins/). Single-precision-float numbers;
immutable strings; `nil` is false and the empty list; no booleans, vectors, hash
tables, keyword args, TCO, or `eval`-from-Lisp.

The kernel is rxi's [Fe](https://github.com/rxi/fe), vendored. Its changes from
upstream Fe:

- **Assignment is `set`, not `=`** — `=` is equality, supplied by Core.
- **Top-level `let` binds globally** instead of being a silent no-op.
- **`GCSTACKSIZE` is compile-time configurable** — default 256, raised to 8192 on
  the desktop build.

Recorded in the [CHANGELOG](https://github.com/Kinoshita-Electronics-Consortium/kec-lisp/blob/main/CHANGELOG.md).

## Core and host primitives

**KEC Core** is the standard library, written in KEC Lisp and loaded into every
context before user code runs: definition macros (`defn`, `defmacro`, `define`),
list/sequence functions, comparison (`=`, `==`, `/=`, `>`, `>=`, …), type
predicates, control macros (`cond`, `case`, `when`, `dotimes`, …), higher-order
functions, and string/format helpers. Its list/sequence functions are written
iteratively. Enumerated in the
[Language Reference §3](/kec-lisp/language/#3-the-standard-library-core).

**Host primitives** are C functions that need only the C library — `type-of`,
math, string ops, I/O, and a few system calls — bound per
[profile](/kec-lisp/ffi-bridge/#4-capability-tiers): `SANDBOX` is the portable
set; `FULL` adds `load` / `slurp` / `args` / `exit`. Enumerated in the
[Language Reference §4](/kec-lisp/language/#4-c-primitives-host).

## The FFI bridge

A C function becomes a KEC Lisp symbol through `kec_bind_fe(ctx, "name", fn)`.
Registration, the C↔Lisp type table, opaque handles, profiles, error
propagation, and arena discipline are on the [FFI Bridge](/kec-lisp/ffi-bridge/)
page. This is how both this repo's host primitives and the firmware's device
primitives are added.

## The KN-86 firmware

The KN-86 firmware vendors this repo and adds its device primitives — graphics,
audio, save state, missions, the CIPHER voice — and the cartridge authoring
macros (`defcell`, `defmission`, …), through the same
[FFI bridge](/kec-lisp/ffi-bridge/). None of that is in this repo. See
[What's Here](/kec-lisp/boundary/).
