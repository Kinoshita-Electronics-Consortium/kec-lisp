---
title: Built-ins
description: The 26 compiled-in kernel primitives of KEC Lisp, with one-line semantics — distinct from the Lisp-authored Core library and the C runtime/host primitives.
---

The KEC Lisp kernel (vendored [Fe](https://github.com/rxi/fe)) ships
**26 compiled-in primitives** — binding, control flow, list ops, predicates,
arithmetic, and one I/O call. This page indexes them with one-line semantics.
Everything else you call comes from one of the two layers above the kernel:

| Source | Fe type | Defined where | Examples |
|---|---|---|---|
| **Kernel built-in** (this page) | `FE_TPRIM` | compiled into `kernel/` | `set`, `cons`, `if` |
| **Runtime / host primitive** | `FE_TCFUNC` | C in `runtime/` or `host/`, bound via `kec_bind_fe` | `try`, `type-of`, `mod`, `princ` |
| **Core / user** | `FE_TFUNC` / `FE_TMACRO` | KEC Lisp in `core/` (or your code) | `map`, `cond`, `defn`, `=` |

So `=`, `map`, `cond`, and `defn` are **not** kernel built-ins — they live in
[Core](/kec-lisp/language/#standard-library-core). The language is the
kernel plus Core plus the runtime/host primitives.

> **Kernel delta from upstream Fe.** KEC names assignment **`set`**, not `=`. That
> frees `=` to mean **equality** (supplied by Core). If you've read upstream Fe
> docs, this is the one thing to re-learn. See the
> [CHANGELOG](https://github.com/Kinoshita-Electronics-Consortium/kec-lisp/blob/main/CHANGELOG.md)
> and [Fe Kernel — Internals](/kec-lisp/fe-kernel/) for the full delta and
> implementation constraints.

---

## Binding and definition

| Built-in | Semantics |
|---|---|
| `(let sym value)` | Bind `sym`. In a body -> a local for the rest of that body; at the top level -> a global. Protected standard globals cannot be rebound. Returns `value`. |
| `(set sym value)` | **Assignment** to an existing binding (or a top-level global). Protected standard globals cannot be rebound. |
| `(fn (params…) body…)` | Construct a closure (lexical). `(fn (a . rest) …)` and `(fn args …)` bind rest/variadic args. |
| `(mac (params…) body…)` | Construct a macro: args unevaluated, the expansion is re-evaluated. |

There is no `define` / `defn` / `defmacro` in the kernel — Core supplies those
(they expand to `set` + `fn`/`mac`).

After the runtime loads Core, load-bearing standard names are protected. A script
that attempts to rebind a kernel primitive such as `cons`, a host primitive, a
Core function such as `map`, or a private Core helper such as `%append` receives
a catchable error and the original global value remains in place. Lexical locals
are still ordinary bindings.

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
| `(setcar p v)` | `Pair Any → nil` | In-place mutation of `car`. Returns `nil`. |
| `(setcdr p v)` | `Pair Any → nil` | In-place mutation of `cdr`. Returns `nil`. |
| `(list a b …)` | `Any… → List` | Build a proper list of the evaluated arguments. |

**No `nth`, `length`, `append`, `reverse`, `member`, or `assoc` in the kernel** —
[Core](/kec-lisp/language/#lists) supplies those, written
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
| `(+ a b …)` | Sum; folds left. Needs at least one argument — `(+)` raises "too few arguments". |
| `(- a b …)` | Subtract; folds left from the first argument. No unary negation: `(- 5)` → 5. Negate with `(- 0 5)`. |
| `(* a b …)` | Product. |
| `(/ a b …)` | Float division — `(/ 7 2)` → 3.5. |
| `(< a b)` | Strict less-than. |
| `(<= a b)` | Less-or-equal. |

No `>`, `>=`, `=`, `mod`, `abs`, or `sqrt` in the kernel: `>` / `>=` / `=` come
from Core; `mod` / `abs` / `sqrt` and friends are host primitives (see the
[Language Reference](/kec-lisp/language/#runtime--host-primitives)).

## I/O

| Built-in | Semantics |
|---|---|
| `(print x …)` | Write each `x` to the configured write function, then a newline. |

`print` is the kernel's only I/O. The runtime/host layers add `princ` /
`newline` / `repr` (and, in the `FULL` profile, file I/O — `load` /
`read-file` / `write-file` / `append-file`, plus `require`). `try` / `raise`
are catchable error control. Length-aware `read-string` parses one value from
text and `read-all` parses every form, both in any profile; `macroexpand-1`
expands one quoted macro call for inspection. `bound?` (including bindings whose
value is `nil`), `globals`, and `fn-params` are read-only reflection over the live
environment (safe in any profile).
`eval` evaluates an already-read data form in the live image — the editor/REPL
keystone — but is a **`FULL`-tier capability**, deliberately not bound into
`SANDBOX` contexts. There is no socket I/O at the kernel level.

Foreign containers are host primitives, not kernel built-ins. The current
portable set includes vectors, flat row-major matrices, hash tables, and
binary-safe blobs; see the [Language Reference](/kec-lisp/language/#containers).

---

## Quick lookup — the full kernel set (source order)

```
let  set  if  fn  mac  while  quote  and  or  do
cons  car  cdr  setcar  setcdr  list  not  is  atom  print
<  <=  +  -  *  /
```

26 entries. Anything you call that isn't in this list is coming from
[Core](/kec-lisp/language/#standard-library-core) (Lisp) or a
[runtime/host primitive](/kec-lisp/language/#runtime--host-primitives)
(C) — or, in the KN-86 firmware, from a device primitive bound through the
[FFI bridge](/kec-lisp/ffi-bridge/).
