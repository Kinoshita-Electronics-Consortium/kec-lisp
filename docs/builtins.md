---
title: Built-ins
description: The 26 compiled-in kernel primitives of KEC Lisp, with one-line semantics — distinct from the Lisp-authored Core library and the C host primitives.
---

The KEC Lisp kernel (vendored [Fe](https://github.com/rxi/fe)) ships
**26 compiled-in primitives** — binding, control flow, list ops, predicates,
arithmetic, and one I/O call. This page indexes them with one-line semantics.
Everything else you call comes from one of the two layers above the kernel:

| Source | Fe type | Defined where | Examples |
|---|---|---|---|
| **Kernel built-in** (this page) | `FE_TPRIM` | compiled into `kernel/` | `set`, `cons`, `if` |
| **Host primitive** | `FE_TCFUNC` | C in `host/`, bound via `kec_bind_fe` | `type-of`, `mod`, `princ` |
| **Core / user** | `FE_TFUNC` / `FE_TMACRO` | KEC Lisp in `core/` (or your code) | `map`, `cond`, `defn`, `=` |

So `=`, `map`, `cond`, and `defn` are **not** kernel built-ins — they live in
[Core](/kec-lisp/language/#3-the-standard-library-core). The language is the
kernel plus Core plus the host primitives.

> **Kernel delta from upstream Fe.** KEC names assignment **`set`**, not `=`. That
> frees `=` to mean **equality** (supplied by Core). If you've read upstream Fe
> docs, this is the one thing to re-learn. See the
> [CHANGELOG](https://github.com/Kinoshita-Electronics-Consortium/kec-lisp/blob/main/CHANGELOG.md).

---

## Binding and definition

| Built-in | Semantics |
|---|---|
| `(let sym value)` | Bind `sym`. In a body → a local for the rest of that body; at the top level → a global. Returns `value`. |
| `(set sym value)` | **Assignment** to an existing binding (or a top-level global). |
| `(fn (params…) body…)` | Construct a closure (lexical). `(fn (a . rest) …)` and `(fn args …)` bind rest/variadic args. |
| `(mac (params…) body…)` | Construct a macro: args unevaluated, the expansion is re-evaluated. |

There is no `define` / `defn` / `defmacro` in the kernel — Core supplies those
(they expand to `set` + `fn`/`mac`).

## Control flow

| Built-in | Semantics |
|---|---|
| `(if cond then else…)` | Conditional; supports cond-style chaining `(if c1 t1 c2 t2 else)`. |
| `(and a b …)` | Short-circuit AND. |
| `(or a b …)` | Short-circuit OR. |
| `(while cond body…)` | Loop while `cond` is truthy; returns `nil`. |
| `(do expr…)` | Sequence; returns the last value. |
| `(quote x)` / `'x` | Suppress evaluation. |

## List operations

| Built-in | Signature | Semantics |
|---|---|---|
| `(cons a b)` | `Any Any → Pair` | Construct a pair (allocated from the arena). |
| `(car p)` | `Pair → Any` | First element. Errors if `p` is not a pair. |
| `(cdr p)` | `Pair → Any` | Rest. Errors if `p` is not a pair. |
| `(setcar p v)` | `Pair Any → Pair` | In-place mutation of `car`. Returns `p`. |
| `(setcdr p v)` | `Pair Any → Pair` | In-place mutation of `cdr`. Returns `p`. |
| `(list a b …)` | `Any… → List` | Build a proper list of the evaluated arguments. |

**No `nth`, `length`, `append`, `reverse`, `member`, or `assoc` in the kernel** —
[Core](/kec-lisp/language/#32-list--list--sequence) supplies those, written
iteratively. Performance-sensitive traversal uses `while` + `setcar`/`setcdr`
rather than deep recursion (the GC-root stack is bounded).

## Predicates

| Built-in | Semantics |
|---|---|
| `(not x)` | True if `x` is `nil`. |
| `(atom x)` | True if `x` is *not* a pair (i.e. `nil`, number, symbol, string, fn, macro, prim, cfunc, or ptr). |
| `(is a b)` | Equality: numbers by value, strings structurally, pairs and other atoms by **identity**. |

There is no `=`, `nil?`, `pair?`, `number?`, … in the kernel. `(not x)` is the
null test and `atom` is leaf detection; Core wraps the rest as named predicates
(some using the host `type-of` primitive).

## Arithmetic & comparison

All numeric ops operate on `fe_Number` (single-precision `float`); the
variadic arithmetic forms fold left.

| Built-in | Semantics |
|---|---|
| `(+ a b …)` | Sum. `(+)` → 0. |
| `(- a b …)` | Subtract. Unary negates: `(- 5)` → -5. |
| `(* a b …)` | Product. |
| `(/ a b …)` | Float division — `(/ 7 2)` → 3.5. |
| `(< a b)` | Strict less-than. |
| `(<= a b)` | Less-or-equal. |

No `>`, `>=`, `=`, `mod`, `abs`, or `sqrt` in the kernel: `>` / `>=` / `=` come
from Core; `mod` / `abs` / `sqrt` and friends are host primitives (see the
[Language Reference §4](/kec-lisp/language/#4-c-primitives-host)).

## I/O

| Built-in | Semantics |
|---|---|
| `(print x …)` | Write each `x` to the configured write function, then a newline. |

`print` is the kernel's only I/O. The host adds `princ` / `newline` / `repr`
(and, in the `FULL` profile, file I/O — `load` / `read-file` / `write-file` /
`append-file`, plus `require`). `read-string` parses a value from text in any
profile, but it is a *reader*, not `eval` — there is still no `eval` from Lisp,
and no socket I/O at the kernel level.

---

## Quick lookup — the full kernel set (source order)

```
let  set  if  fn  mac  while  quote  and  or  do
cons  car  cdr  setcar  setcdr  list  not  is  atom  print
<  <=  +  -  *  /
```

26 entries. Anything you call that isn't in this list is coming from
[Core](/kec-lisp/language/#3-the-standard-library-core) (Lisp) or a
[host primitive](/kec-lisp/language/#4-c-primitives-host) (C) — or, in the
KN-86 firmware, from a device primitive bound through the
[FFI bridge](/kec-lisp/ffi-bridge/).
