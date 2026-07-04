---
title: Core Library Reference
description: Every public function and macro in KEC Core (core/*.lsp), by module, with signatures, parameters, and verified examples.
---

**KEC Core** is the standard library: written entirely in KEC Lisp, loaded into
every context before user code runs, in the numeric filename order below
(`00-def` → `70-sort`). This page is the full per-function reference — every
public binding, in source order, with a tested example. For a lighter cheat
sheet, see the [Language Reference](/kec-lisp/language/#standard-library-core);
for how Core fits alongside the kernel and the runtime/host primitives, see
[Language Standard](/kec-lisp/language-standard/).

Private, `%`-prefixed helpers (`%append`, `%qq`, `%plists`, …) are internal
expansion/bootstrap machinery, not public API — they're mentioned in passing
where they matter, but don't get their own entries. Every example on this page
was run for real against `./build/kec eval` — nothing here is guessed output.

### `core/00-def.lsp` — ergonomic definition macros (`defn` / `defmacro` / `define`)

The kernel has no `define`/`defun`/`defmacro` — only `set` and `fn`/`mac`. This file supplies
the three definition forms every other Core module (and cart author) uses. All three
expand to a `(do (set name ...) name)` shape: `set` itself returns `nil`, so each macro
evaluates `name` last to hand back the thing it just defined (the function, macro, or
value), making definitions chainable and giving the REPL something useful to echo. `set`
keeps its normal scoping rules (top-level global, or an existing binding) — only the
return value changes.

#### `(defn name (params...) body...)`

Defines `name` as a function (`fn`) and returns the function. Expands to
`(do (set name (fn (params...) body...)) name)`.

- **Parameters:** `name` — symbol to bind; `params` — the `fn` parameter list (supports `.` rest-arg and bare variadic symbol); `body` — one or more body forms.
- **Returns:** the newly created function object.

```lisp
(defn sq (x) (* x x))  ; => [func 0x434fe5a30]
(do (defn sq (x) (* x x)) (sq 5))  ; => 25
```

#### `(defmacro name (params...) body...)`

Defines `name` as a macro (`mac`) and returns the macro. Expands to
`(do (set name (mac (params...) body...)) name)`. Macro args are unevaluated; the body
produces a form that is re-evaluated in the caller's context.

- **Parameters:** `name` — symbol to bind; `params` — macro parameter list; `body` — forms that build the expansion.
- **Returns:** the newly created macro object.

```lisp
(defmacro twice (x) (list 'do x x))  ; => [macro 0x446fe5a00]
(do (defmacro twice (x) (list 'do x x)) (twice (print 1)))
;; prints 1 twice, evaluates to nil (print's return value)
```

#### `(define name value)` / `(define (f args...) body...)`

Two forms in one macro, dispatched on whether the head is an atom or a pair. `(define name
value)` sets `name` to `value` and returns the value. `(define (f args...) body...)` is
Scheme-style function-definition sugar — it defines `f` as a function of `args...` and
returns `f`. Distinguished from `defn` only by call-site syntax (parens around
name+params vs. separate arguments); both ultimately bind an `fn`.

- **Parameters:** `name`/`value` — a symbol and the value to bind it to, **or** `(f args...)` — a call-shaped head, plus `body` — the function body.
- **Returns:** the bound value (atom form) or the newly created function (fn-shape form).

```lisp
(do (define x 10) x)  ; => 10
(do (define (add a b) (+ a b)) (add 2 3))  ; => 5
```

**Note:** `define`'s two shapes make it read differently from `defn`/`defmacro` at a
glance — `(define x 10)` returns `10` (the value), while `(define (add a b) ...)` returns
the function itself, matching `defn`'s return convention. Pick `defn` for the common
function case and reserve `define` for callers translating Scheme-style code or wanting a
single form for both constants and functions.

---

### `core/10-list.lsp` — list & sequence operations

The kernel ships only `cons`/`car`/`cdr`/`setcar`/`setcdr`/`list`. This file adds
traversal and construction helpers, all written **iteratively** with `while` so list
length — not GC-stack depth — bounds their cost. It depends on nothing but the kernel
(no predicate names), so it can load before `core/30-pred.lsp`.

#### `(nth xs i)`

Returns the 0-indexed element of `xs` at position `i`, walking `cdr` `i` times.

- **Parameters:** `xs` — a list; `i` — a 0-based index.
- **Returns:** the element at `i`, or `nil` if `i` is past the end of the list.

```lisp
(nth (list 10 20 30) 1)  ; => 20
(nth (list 10 20 30) 5)  ; => nil
```

#### `(length xs)`

Counts the elements of a proper list by walking `cdr` until `nil`.

- **Parameters:** `xs` — a proper list.
- **Returns:** the element count (an integer-valued float).

```lisp
(length (list 1 2 3))  ; => 3
(length nil)            ; => 0
```

#### `(reverse xs)`

Builds a new list with `xs`'s elements in reverse order.

- **Parameters:** `xs` — a list.
- **Returns:** a new, reversed list.

```lisp
(reverse (list 1 2 3))  ; => (3 2 1)
```

#### `(append a b)`

Concatenates `a` and `b`, returning a fresh list. Non-destructive with respect to `a`:
elements of `a` are consed onto `b` after reversing a copy of `a`, so the original `a`
list structure is untouched. This is the public, shadowable name; a private snapshot
(`%append`, captured at load time) is what quasiquote's `,@` uses internally so a cart
that shadows `append` can't silently corrupt macro expansion.

- **Parameters:** `a` — the list whose elements are copied; `b` — the list appended onto (shared structure, not copied).
- **Returns:** a new list `a`'s elements followed by `b`.

```lisp
(append (list 1 2) (list 3 4))  ; => (1 2 3 4)
(append nil (list 1))            ; => (1)
```

**Note:** confirmed non-destructive — `(do (let a (list 1 2)) (let b (append a (list 3))) (list a b))` => `((1 2) (1 2 3))`; the original `a` is unmodified.

#### `(last xs)`

Walks to the final `cdr` and returns the last element.

- **Parameters:** `xs` — a non-empty list.
- **Returns:** the last element.

```lisp
(last (list 1 2 3))  ; => 3
```

#### `(member x xs)`

Searches `xs` for the first element equal to `x` under `is` (value equality for
numbers/strings, identity for pairs/symbols).

- **Parameters:** `x` — value to search for; `xs` — a list.
- **Returns:** the tail of `xs` beginning at the first matching element (not just the element itself), or `nil` if not found.

```lisp
(member 2 (list 1 2 3))  ; => (2 3)
(member 9 (list 1 2 3))  ; => nil
```

#### `(assoc k alist)`

Searches an association list (a list of pairs) for the first pair whose `car` matches `k`
under `is`.

- **Parameters:** `k` — key to search for; `alist` — a list of `(key . value)` pairs.
- **Returns:** the matching pair, or `nil` if not found.

```lisp
(assoc 'b (list (cons 'a 1) (cons 'b 2)))  ; => (b . 2)
(assoc 'z (list (cons 'a 1)))               ; => nil
```

#### `(take xs n)`

Returns the first `n` elements of `xs`.

- **Parameters:** `xs` — a list; `n` — count of elements to take.
- **Returns:** a new list of up to `n` elements — fewer if `xs` is shorter than `n`.

```lisp
(take (list 1 2 3 4) 2)  ; => (1 2)
(take (list 1 2) 5)       ; => (1 2)
```

#### `(drop xs n)`

Returns `xs` with the first `n` elements removed.

- **Parameters:** `xs` — a list; `n` — count of elements to skip.
- **Returns:** the tail of `xs` after skipping `n` elements (`nil` if `n` >= length).

```lisp
(drop (list 1 2 3 4) 2)  ; => (3 4)
(drop (list 1 2 3) 10)    ; => nil
```

#### `(range a b)`

Builds the list of integers from `a` up to but not including `b`.

- **Parameters:** `a` — inclusive start; `b` — exclusive end.
- **Returns:** the list `(a a+1 ... b-1)`; `nil` if `a >= b`.

```lisp
(range 0 5)  ; => (0 1 2 3 4)
(range 3 3)  ; => nil
(range 5 2)  ; => nil
```

---

### `core/15-math.lsp` — math constants (ADR-0005)

Defines the two Core-level math constants. Trig primitives (`sin`/`cos`/`tan`/`atan2`)
and time primitives (`now`/`clock`) are C host primitives in `host/host.c`; `pi` and `tau`
live here as plain Core constants (via `define`) rather than host cfuncs because a bare
constant reads more naturally than a `(pi)` call. `fe_Number` is single-precision float,
so both are rounded to about 7 significant digits on read — fine for geometry/CRT work,
not for high-iteration numerical accumulation.

#### `pi`

The constant π, rounded to single-float precision.

- **Returns:** `3.14159265358979` as authored, read back as single-precision float.

```lisp
pi  ; => 3.141593
```

#### `tau`

The constant τ = 2π (one full turn), rounded to single-float precision.

- **Returns:** `6.28318530717959` as authored, read back as single-precision float.

```lisp
tau  ; => 6.283185
```

---

### `core/20-cmp.lsp` — equality & comparison

The kernel ships only `<`, `<=`, and `is`. This file completes the comparison set. The
KEC kernel names assignment `set` (not `=` as upstream Fe did), freeing `=` for its
conventional meaning as equality. `=`, `==`, and `is` are the same comparison underneath:
value equality for numbers and strings, identity for symbols and pairs. `/=` is the
negation.

#### `(= a b)`

Value/identity equality — a thin wrapper directly delegating to the kernel `is`.

- **Parameters:** `a`, `b` — any values.
- **Returns:** `t`-ish truthy value if equal, `nil` otherwise. Numbers and strings compare by value; pairs and symbols compare by identity.

```lisp
(= 1 1)              ; => t
(= 1 2)              ; => nil
(= "a" "a")          ; => t
(= (list 1 2) (list 1 2))  ; => nil
```

**Note:** confirmed the pairs-by-identity gotcha from the language reference: two
structurally identical freshly-consed lists are `nil` under `=` since they're different
objects — use a structural-equality helper (not present in these four files) if you need
deep comparison.

#### `(== a b)`

Alias for `=`, provided for readers coming from C-family languages.

- **Parameters:** `a`, `b` — any values.
- **Returns:** same as `(= a b)`.

```lisp
(== 3 3)  ; => t
```

#### `(/= a b)`

Negation of `=`.

- **Parameters:** `a`, `b` — any values.
- **Returns:** `t`-ish if `a` and `b` are *not* equal, `nil` if they are.

```lisp
(/= 1 2)  ; => t
(/= 1 1)  ; => nil
```

#### `(> a b)`

Strict greater-than, defined as `(not (<= a b))`.

- **Parameters:** `a`, `b` — numbers.
- **Returns:** truthy if `a > b`.

```lisp
(> 2 1)  ; => t
```

#### `(>= a b)`

Greater-or-equal, defined as `(not (< a b))`.

- **Parameters:** `a`, `b` — numbers.
- **Returns:** truthy if `a >= b`.

```lisp
(>= 2 2)  ; => t
```

#### `(zero? n)`

Tests whether `n` is exactly `0` (via `is`).

- **Parameters:** `n` — a number.
- **Returns:** truthy if `n` is `0`.

```lisp
(zero? 0)  ; => t
(zero? 1)  ; => nil
```

#### `(positive? n)`

Tests whether `n` is strictly greater than `0`.

- **Parameters:** `n` — a number.
- **Returns:** truthy if `n > 0`.

```lisp
(positive? 3)  ; => t
```

#### `(negative? n)`

Tests whether `n` is strictly less than `0`.

- **Parameters:** `n` — a number.
- **Returns:** truthy if `n < 0`.

```lisp
(negative? -3)  ; => t
```

#### `(min a . rest)`

Folds over a variadic argument list, returning the smallest.

- **Parameters:** `a` — first value (required); `rest` — zero or more additional values.
- **Returns:** the minimum of all arguments.

```lisp
(min 5 3 8 1)  ; => 1
(min 5)         ; => 5
```

#### `(max a . rest)`

Folds over a variadic argument list, returning the largest.

- **Parameters:** `a` — first value (required); `rest` — zero or more additional values.
- **Returns:** the maximum of all arguments.

```lisp
(max 5 3 8 1)  ; => 8
```
---

### `core/25-alist.lsp` — structural equality and association-list records

#### `(equal? a b)`

Structural (deep) equality. Recurses through pairs comparing `car`/`car` and `cdr`/`cdr`; falls back to `(is a b)` for atoms (numbers by value, strings structurally, other atoms by identity). Exists because the kernel's `is` compares pairs by identity, not contents.

- **Parameters:** a, b — any values.
- **Returns:** `1` if structurally equal, `nil` otherwise.

```lisp
(equal? (list 1 2 3) (list 1 2 3))  ; => 1
(equal? (list 1 2 3) (list 1 2 4))  ; => nil
(= (list 1 2) (list 1 2))           ; => nil  (`=` keeps identity semantics on pairs)
```

**Note:** `equal?` returns the number `1` for true, not a symbol — unlike most Core predicates (`nil?`, `pair?`, `has?`, etc.), which return the symbol `t`.

#### `(get k alist . default)`

Look up key `k` in an association list (a list of `(key . value)` pairs), using `assoc` (identity comparison on keys). Returns an optional `default` when the key is absent.

- **Parameters:** k — key to look up (compared by `is`); alist — list of `(key . value)` pairs; default — optional value returned when `k` is not found (defaults to `nil`).
- **Returns:** the value bound to `k`, or `default`/`nil`.

```lisp
(get 'b (list (cons 'a 1) (cons 'b 2)))          ; => 2
(get 'z (list (cons 'a 1)))                      ; => nil
(get 'z (list (cons 'a 1)) 'default-val)         ; => default-val
```

#### `(has? k alist)`

Test whether key `k` is present in `alist`.

- **Parameters:** k — key; alist — association list.
- **Returns:** `t` if present, `nil` otherwise.

```lisp
(has? 'a (list (cons 'a 1)))  ; => t
(has? 'z (list (cons 'a 1)))  ; => nil
```

#### `(put k v alist)`

Return a **new** alist with key `k` bound to `v`. If `k` already exists, its pair is replaced in place (order preserved); otherwise a new `(k . v)` pair is prepended. Does not mutate the input.

- **Parameters:** k — key; v — value; alist — association list.
- **Returns:** a new association list.

```lisp
(put 'a 99 (list (cons 'a 1) (cons 'b 2)))  ; => ((a . 99) (b . 2))
(put 'c 3  (list (cons 'a 1) (cons 'b 2)))  ; => ((c . 3) (a . 1) (b . 2))
```

#### `(keys alist)`

Collect all keys, in order.

- **Parameters:** alist — association list.
- **Returns:** a list of keys.

```lisp
(keys (list (cons 'a 1) (cons 'b 2)))  ; => (a b)
```

#### `(values alist)`

Collect all values, in order.

- **Parameters:** alist — association list.
- **Returns:** a list of values.

```lisp
(values (list (cons 'a 1) (cons 'b 2)))  ; => (1 2)
```

#### `(merge a b)`

Fold every pair of `b` into `a` via `put` (`b`'s values win on key collision), left to right.

- **Parameters:** a — base association list; b — association list whose entries are applied on top.
- **Returns:** a new association list.

```lisp
(merge (list (cons 'a 1) (cons 'b 2)) (list (cons 'b 20) (cons 'c 3)))
; => ((c . 3) (a . 1) (b . 20))
```

---

### `core/26-plist.lsp` — symbol property registry (get-prop / put-prop)

Classic Lisp symbol properties, named `get-prop`/`put-prop` (not `get`/`put`, which `25-alist.lsp` already claims for alist records). Backed by a private side-table `%plists` (an alist of `sym -> (alist of key -> val)`); symbols and keys compare by identity. Intended home for per-symbol metadata (indentation rules, docstrings, a `disabled` flag) that nEmacs/kec-mode tooling wants.

#### `(put-prop sym key val)`

Store or overwrite property `key` of `sym`.

- **Parameters:** sym — symbol to annotate; key — property name (compared by identity); val — value to store.
- **Returns:** `val`.

```lisp
(do (put-prop 'foo 'doc "a symbol") (get-prop 'foo 'doc))  ; => a symbol
(do (put-prop 'foo 'a 1) (put-prop 'foo 'b 2) (put-prop 'foo 'a 99) (get-prop 'foo 'a))
; => 99
```

#### `(get-prop sym key)`

Read property `key` of `sym`.

- **Parameters:** sym — symbol; key — property name.
- **Returns:** the stored value, or `nil` if `sym` or `key` was never set.

```lisp
(get-prop 'unknown-sym 'doc)  ; => nil
```

---

### `core/30-pred.lsp` — type predicates

`nil?`/`pair?`/`even?`/`odd?` are ordinary KEC Lisp; `number?`/`symbol?`/`string?`/`fn?` read the value's Fe type tag via the host primitive `(type-of x)` since the kernel gives no other way to inspect a tag.

#### `(nil? x)`

Test for `nil` (equivalent to the kernel `not`, given a predicate name).

- **Returns:** `t` if `x` is `nil`, else `nil`.

```lisp
(nil? nil)  ; => t
(nil? 0)    ; => nil
```

#### `(pair? x)`

Test for a cons cell (i.e. not an atom).

- **Returns:** `t` if `x` is a pair, else `nil`.

```lisp
(pair? (list 1 2))  ; => t
(pair? nil)          ; => nil
```

#### `(even? n)`

Test numeric parity via the host primitive `mod`.

- **Parameters:** n — a number.
- **Returns:** `t` if `n mod 2` is `0`, else `nil`.

```lisp
(even? 4)  ; => t
```

#### `(odd? n)`

Complement of `even?`.

```lisp
(odd? 4)  ; => nil
```

#### `(number? x)`

- **Returns:** `t` if `(type-of x)` is `:number`.

```lisp
(number? 3)    ; => t
(number? "3")  ; => nil
```

#### `(symbol? x)`

- **Returns:** `t` if `(type-of x)` is `:symbol`.

```lisp
(symbol? 'a)  ; => t
```

#### `(string? x)`

- **Returns:** `t` if `(type-of x)` is `:string`.

```lisp
(string? "hi")  ; => t
```

#### `(fn? x)`

- **Returns:** `t` if `(type-of x)` is `:fn` — true only for closures built by `(fn ...)`.

```lisp
(fn? (fn (x) x))  ; => t
(fn? car)         ; => nil
```

**Note:** `fn?` is `nil` for kernel built-ins (tag `:prim`, e.g. `car`) and for host/runtime primitives (tag `:cfunc`, e.g. `try`) — it only recognizes Lisp-level closures, not the compiled-in or C-registered callables that also accept arguments like functions.

---

### `core/35-error.lsp` — small error value vocabulary

Defines the shape every error-handling form in Core agrees on: an error is a pair `(:error . message)`. Builds on the runtime's `try`/`raise` primitives (documented elsewhere) — this file just names the convention.

#### `(error message)`

Construct an error value.

- **Parameters:** message — typically a string, but any value is accepted (the shape doesn't constrain it).
- **Returns:** `(:error . message)`.

```lisp
(error "boom")  ; => (:error . "boom")
```

#### `(error? x)`

Test whether `x` has the error shape (a pair whose `car` is `:error`).

- **Returns:** `t` if `x` is `(:error . anything)`, else `nil`.

```lisp
(error? (error "boom"))          ; => t
(error? 42)                      ; => nil
(error? (try (fn () (raise "bad thing"))))
; => t   (the runtime's raised-error value has the same :error shape)
```

#### `(error-message e)`

Extract the message from an error value (just `cdr`).

- **Parameters:** e — an error value, `(:error . message)`.
- **Returns:** the message.

```lisp
(error-message (error "boom"))  ; => boom
```

---

### `core/36-recover.lsp` — error-recovery macros over try/raise

Higher-level recovery macros built on the runtime's `try`/`raise` (documented elsewhere) and the `35-error.lsp` vocabulary. This module loads before `45-quasiquote.lsp`, so all three macros hand-build their expansions with `list`/`cons` rather than backtick/comma.

#### `(unwind-protect body . cleanup)`

Run `body`, then **always** run the `cleanup` forms — on normal return and on a raised error alike. On error, cleanup runs *first*, then the original error is re-raised (message-only, since KEC errors carry just a message) so an enclosing handler still observes the failure.

- **Parameters:** body — a single form to evaluate; cleanup — one or more forms run unconditionally afterward.
- **Returns:** `body`'s value on success. On error, nothing is returned locally — the error is re-raised to the caller.

```lisp
(unwind-protect (+ 1 2) (princ "cleanup ran") (princ "|"))
; prints: cleanup ran|
; => 3

;; error case (wrapped in try to observe the re-raise from outside):
(try (fn ()
  (unwind-protect
    (raise "boom")
    (princ "cleanup-ran\n"))))
; prints: cleanup-ran
; => (:error . "boom")
```

**Note:** verified concretely — the cleanup's `princ` output appears *before* the outer `try` sees the re-raised `(:error . "boom")`, confirming cleanup-runs-before-propagation on the error path.

#### `(ignore-errors . body)`

Evaluate `body`, swallowing any raised error.

- **Parameters:** body — one or more forms (only the *macro's* body sequencing matters; internally it's wrapped in a single `(fn nil body...)`).
- **Returns:** the body's value, or `nil` if evaluation raised an error.

```lisp
(ignore-errors (+ 1 2))                    ; => 3
(ignore-errors (raise "kaboom") (+ 1 2))   ; => nil
(ignore-errors (car nil))                  ; => nil   (kernel's car errors on non-pairs)
```

#### `(condition-case var bodyform . handlers)`

Evaluate `bodyform`. If it raises, bind `var` to the resulting `(:error . message)` value and run the **first** handler clause's body; any additional handler clauses are ignored (message-based catch-all only — no class dispatch yet). With zero handlers, the error value (or the success value) is simply returned.

- **Parameters:** var — symbol bound to the error value inside the handler; bodyform — the form to evaluate; handlers — handler clause(s); only the first is used.
- **Returns:** `bodyform`'s value on success; otherwise the first handler's body value (or the raw error value if no handler is given).

```lisp
(condition-case e (+ 1 2))                                  ; => 3  (no error, no handlers)
(condition-case e (raise "oops"))                            ; => (:error . "oops")  (no handlers)
(condition-case e (raise "oops") (e (str "parse failed: " (error-message e))))
; => "parse failed: oops"
```

**Note:** the handler clause's *head* is discarded — `condition-case` expands each handler form as `(cdr (car handlers))`, i.e. it treats the handler like `(anything body-form...)` and only keeps `body-form...`. The canonical idiom writes the bound `var` again as that throwaway head (`(e ...)`, matching `docs/language.md`'s example), but literally any head works: `(condition-case e (raise "oops") (list 1 2 3))` evaluates `1`, `2`, then `3` as three body forms and returns `3` — the `list` head is never called. Also confirmed: a second handler clause, e.g. `(condition-case e (raise "oops") (h1 42) (h2 999))`, is silently ignored — only `(h1 42)` runs.

#### `(macroexpand form)`

Fully expand `form`, repeatedly applying the host primitive `macroexpand-1` (documented elsewhere) to a fixpoint. `macroexpand-1` returns the identical object (by `is`) once nothing more expands, which terminates the loop.

- **Parameters:** form — a form to expand (need not be a macro call; non-macros expand to themselves immediately).
- **Returns:** the fully expanded form.

```lisp
(macroexpand '(ignore-errors (+ 1 2)))
; => (do (let %g0 (try (fn nil (+ 1 2)))) (if (error? %g0) nil %g0))
```
---

### `core/40-ctrl.lsp` — control macros (`when`/`unless`/`cond`/`case`/`let*`/`letrec`/`dotimes`/`dolist`/`begin`)

Kernel ships `if`/`and`/`or`/`do`/`while`; this module adds the macros every
real program reaches for. It loads before quasiquote, so every expander here
is still hand-built with `list`/`cons` — no `` ` ``/`,` sugar yet. Per the
robustness contract (see file header, AMOP §4.2.2), each macro's expander and
emitted code bottom out on frozen kernel primitives only, never on a
shadowable Core function, so a cart that redefines e.g. `member` or `append`
can't silently corrupt these macros.

#### `(when test body...)`

Runs `body` only if `test` is truthy. Expands to `(if test (do body...) nil)`.

- **Parameters:** test — condition form; body — zero or more forms run in sequence when `test` is truthy.
- **Returns:** the last body form's value, or `nil` if `test` is falsy.

```lisp
(when (> 3 2) (print "yes") 42)  ; => prints "yes", returns 42
(when (> 2 3) 42)                ; => nil
```

#### `(unless test body...)`

Runs `body` only if `test` is falsy — the inverse of `when`. Expands to `(if test nil (do body...))`.

- **Parameters:** test — condition form; body — zero or more forms run in sequence when `test` is falsy.
- **Returns:** the last body form's value, or `nil` if `test` is truthy.

```lisp
(unless (> 2 3) 42)  ; => 42
(unless (> 3 2) 42)  ; => nil
```

#### `(cond (test body...) ... )`

Multi-branch conditional. Evaluates each clause's `test` in order and runs the `body` of the first truthy one; `else` as a clause's test is a catch-all. No matching clause (and no `else`) yields `nil`.

- **Parameters:** clauses — each a list `(test body...)`; `test` may be the literal symbol `else`.
- **Returns:** the last form of the winning clause's body, or `nil` if none match.

```lisp
(cond ((> 1 2) 'a) ((> 3 2) 'b) (else 'c))  ; => b
(cond ((> 1 2) 'a) (else 'c))               ; => c
(cond ((> 1 2) 1))                          ; => nil
```

#### `(case key (vals body...) ... )`

Evaluates `key` once, then compares it (via `is`) against each clause's `vals` — a single datum or a list of data — running the `body` of the first clause that matches. `else` is a catch-all. The expansion binds `key` to a `gensym` temporary and builds an `(or (is tmp 'v1) (is tmp 'v2) ...)` chain per clause rather than calling `member`, so it never depends on a shadowable function.

- **Parameters:** key — form evaluated once; clauses — each a list `(vals body...)`, where `vals` is one datum or a list of data to match against, or the symbol `else`.
- **Returns:** the last form of the matching clause's body, or `nil` if none match.

```lisp
(case 2 (1 'one) ((2 3) 'two-or-three) (else 'other))  ; => two-or-three
(case 9 (1 'one) (else 'other))                         ; => other
(case 5 (5 'five) (else 'other))                        ; => five
```

#### `(let* ((sym val)...) body...)`

Sequential local bindings — each `val` form can see the `sym`s bound earlier in the same `let*` (kernel `let` only binds one pair at a time and doesn't sequence). Expands to a flat `do` of successive `let`s followed by `body`.

- **Parameters:** binds — list of `(sym val)` pairs, bound left to right; body — forms run after all bindings are in place.
- **Returns:** the last body form's value.

```lisp
(let* ((a 1) (b (+ a 1)) (c (+ b 1))) (list a b c))  ; => (1 2 3)
```

#### `(letrec ((sym val)...) body...)`

Mutually-recursive local bindings: declares all `sym`s to `nil` first, then assigns each `val` in a second pass, so any `val` form (typically a `fn`) can reference the others' names before they're filled in. Necessary for defining local functions that call each other.

- **Parameters:** binds — list of `(sym val)` pairs, all pre-declared before any is assigned; body — forms run after assignment.
- **Returns:** the last body form's value.

```lisp
(letrec ((even? (fn (n) (if (is n 0) 1 (odd? (- n 1)))))
         (odd?  (fn (n) (if (is n 0) nil (even? (- n 1))))))
  (even? 10))
; => 1
```

#### `(dotimes (var limit) body...)`

Runs `body` with `var` bound to each integer from `0` up to (not including) `limit`. Built on kernel `while` with a `gensym`-named limit temporary so the loop shape is fixed and needs no `append`.

- **Parameters:** var — loop variable, rebound each iteration; limit — form evaluated once for the exclusive upper bound; body — forms run once per iteration.
- **Returns:** `nil` (the underlying `while`'s return value).

```lisp
(do (let acc nil)
    (dotimes (i 5) (set acc (cons i acc)))
    (reverse acc))
; => (0 1 2 3 4)
```

#### `(dolist (var list-form) body...)`

Runs `body` with `var` bound to each element of `list-form` in order.

- **Parameters:** var — loop variable, rebound each iteration to the current element; list-form — form evaluated once, yielding the list to walk; body — forms run once per element.
- **Returns:** `nil`.

```lisp
(do (let acc nil)
    (dolist (x (list 10 20 30)) (set acc (cons (* x 2) acc)))
    (reverse acc))
; => (20 40 60)
```

#### `(begin body...)`

Alias for the kernel `do` sequence — runs each form in order.

- **Parameters:** body — zero or more forms run in sequence.
- **Returns:** the last form's value.

```lisp
(begin (print "a") (print "b") 3)  ; => prints "a" then "b", returns 3
```

---

### `core/45-quasiquote.lsp` — quasiquote/unquote/unquote-splicing expansion

Defines the macro that backs the reader sugar `` ` `` / `,` / `,@`
(`quasiquote` / `unquote` / `unquote-splicing`), letting you build list
templates without writing raw `cons`/`list`/`quote` calls. The expander
(`%qq`, `%qq-list`) is private machinery: it walks the quasiquoted form,
turning literal atoms into `(quote atom)`, `,x` into `x` verbatim, `,@xs`
splices into a call to `%append` (the load-time-captured `append`, not the
public shadowable one — same robustness contract as `40-ctrl.lsp`), and
everything else into nested `cons` calls. It uses only kernel primitives
(`atom`/`car`/`cdr`/`is`/`and`/`not`/`list`) internally.

#### `(quasiquote x)`

Template-builds `x`: literal data is quoted as-is, `(unquote y)` (`,y`) substitutes the evaluated `y` in place, and `(unquote-splicing ys)` (`,@ys`) splices the evaluated list `ys` in place of one element. Normally written with the reader sugar rather than called directly.

- **Parameters:** x — a quasiquoted template, generally supplied via `` `x `` syntax.
- **Returns:** the constructed list/value with all unquotes and splices resolved.

```lisp
`(1 2 3)                                    ; => (1 2 3)
(let x 5) `(a ,x c)                         ; => (a 5 c)
(let xs (list 2 3 4)) `(1 ,@xs 5)           ; => (1 2 3 4 5)
(let a 1) (let b 2) `(x (,a ,b) y)          ; => (x (1 2) y)
(let xs (list 1 2)) (let ys (list 3 4))
`(,@xs mid ,@ys)                            ; => (1 2 mid 3 4)
```

**Note:** `macroexpand-1` on `` `(1 ,x) `` shows the raw expansion: `(cons (quote 1) (cons x (quote nil)))` — confirming unquoted subforms are spliced in as live code, everything else as quoted data.

---

### `core/50-hof.lsp` — higher-order list functions (map/filter/fold/search)

All traversals here are iterative (`while` + accumulator + final `reverse`),
never recursive — the GC root stack is small and fixed (256 frames on
memory-tight hosts), so a recursive `map`/`filter` over a long list would
overflow it. Iteration keeps stack depth constant regardless of list length.

#### `(map f xs)`

Applies `f` to each element of `xs` in order, collecting the results into a new list of the same length.

- **Parameters:** f — one-argument function; xs — list to traverse.
- **Returns:** a new list of `(f x)` for each `x` in `xs`, same order.

```lisp
(map (fn (x) (* x x)) (list 1 2 3 4))  ; => (1 4 9 16)
```

#### `(filter pred xs)`

Keeps only the elements of `xs` for which `pred` is truthy, preserving order.

- **Parameters:** pred — one-argument predicate; xs — list to traverse.
- **Returns:** a new list of the elements satisfying `pred`.

```lisp
(filter (fn (x) (> x 2)) (list 1 2 3 4 5))  ; => (3 4 5)
```

#### `(remove pred xs)`

Keeps only the elements of `xs` for which `pred` is falsy — the complement of `filter`. Implemented as `(filter (fn (x) (not (pred x))) xs)`.

- **Parameters:** pred — one-argument predicate; xs — list to traverse.
- **Returns:** a new list of the elements *not* satisfying `pred`.

```lisp
(remove (fn (x) (> x 2)) (list 1 2 3 4 5))  ; => (1 2)
```

#### `(fold-left f init xs)`

Left fold (a.k.a. reduce): walks `xs` left to right, threading an accumulator through `f`. Each step calls `f` as `(f accumulator element)` — accumulator first.

- **Parameters:** f — two-argument function `(acc x) -> acc'`; init — initial accumulator value; xs — list to traverse.
- **Returns:** the final accumulator value.

```lisp
(fold-left - 0 (list 1 2 3))  ; => -6   ; ((0-1)-2)-3
(fold-left (fn (acc x) (cons x acc)) nil (list 1 2 3))  ; => (3 2 1)
```

#### `(fold-right f init xs)`

Right fold: conceptually walks `xs` right to left, calling `f` as `(f element accumulator)` — element first, the opposite argument order from `fold-left`. Implemented iteratively (to avoid recursion) as `fold-left` with the operation's arguments flipped, over the reversed list — same asymptotic cost as `fold-left`, no actual right-to-left recursion.

- **Parameters:** f — two-argument function `(x acc) -> acc'`; init — initial accumulator value; xs — list to traverse.
- **Returns:** the final accumulator value.

```lisp
(fold-right - 0 (list 1 2 3))          ; => 2    ; 1-(2-(3-0))
(fold-right cons nil (list 1 2 3))     ; => (1 2 3)   ; rebuilds the list
```

**Note:** on a non-commutative op like `-`, `fold-left` and `fold-right` give different answers from the same inputs (`-6` vs `2`) — the argument-order flip is the whole point, not just a stylistic difference. `(fold-right cons nil xs)` is the classic identity-preserving fold, useful as a sanity check on the argument order.

#### `(for-each f xs)`

Calls `f` on each element of `xs` in order, for side effects only — discards the results.

- **Parameters:** f — one-argument function, called for its side effect; xs — list to traverse.
- **Returns:** `nil`.

```lisp
(for-each (fn (x) (print x)) (list 1 2 3))
; prints 1, 2, 3 on separate lines => nil
```

#### `(find pred xs)`

Returns the first element of `xs` satisfying `pred`, stopping as soon as one is found.

- **Parameters:** pred — one-argument predicate; xs — list to traverse.
- **Returns:** the first matching element, or `nil` if none match.

```lisp
(find (fn (x) (> x 2)) (list 1 2 3 4))   ; => 3
(find (fn (x) (> x 20)) (list 1 2 3 4))  ; => nil
```

#### `(any? pred xs)`

Short-circuiting existential test: returns the first truthy result of `(pred x)` — not just `1`/`t` but whatever `pred` actually returned — stopping at the first hit.

- **Parameters:** pred — one-argument predicate; xs — list to traverse.
- **Returns:** the first truthy `(pred x)` value, or `nil` if none are truthy.

```lisp
(any? (fn (x) (> x 3)) (list 1 2 3 4))   ; => t
(any? (fn (x) (> x 30)) (list 1 2 3 4))  ; => nil
```

**Note:** `any?` returns whatever `pred` returned, unnormalized — here `t`, because `>` itself returns the symbol `t`. Don't rely on `any?`'s truthy result being `1`; test its truthiness with `if`/`when`, not `(is (any? ...) 1)`.

#### `(every? pred xs)`

Short-circuiting universal test: returns `1` if `pred` is truthy for every element of `xs`, stopping (and returning `nil`) at the first failure. An empty list is vacuously true (`1`).

- **Parameters:** pred — one-argument predicate; xs — list to traverse.
- **Returns:** `1` if all elements satisfy `pred`, else `nil`.

```lisp
(every? (fn (x) (> x 0)) (list 1 2 3 4))  ; => 1
(every? (fn (x) (> x 2)) (list 1 2 3 4))  ; => nil
```

#### `(count pred xs)`

Counts the elements of `xs` satisfying `pred`.

- **Parameters:** pred — one-argument predicate; xs — list to traverse.
- **Returns:** the count, a number.

```lisp
(count (fn (x) (> x 2)) (list 1 2 3 4 5))  ; => 3
```
---

### `core/52-container.lsp` — Lisp conveniences layered over the vector/matrix/hash/blob C primitives (ADR-0003)

This module doesn't define containers — `make-vector`, `vector-ref`, `vector-set!`,
`make-matrix`, `matrix-ref`, `matrix-set!`, `make-hash-table`, `hash-set!`,
`hash-ref`, `hash-has?`, `hash-del!`, `hash-count`, `hash-keys`, and friends are
host primitives, documented elsewhere. What's here are the iterative Lisp
helpers built on top: list conversion, fill/copy, and the higher-order
`for-each`/`map` shapes for vectors, matrices, and hashes. Loads after 50 (HOF)
so it can call `map`/`for-each`.

#### `(vector->list v)`

Returns a fresh list of `v`'s elements in order.

- **Parameters:** `v` — a vector.
- **Returns:** a new list (does not alias the vector).

```lisp
(vector->list (vector 1 2 3))  ; => (1 2 3)
(vector->list (make-vector 0 nil))  ; => nil
```

#### `(list->vector xs)`

Returns a fresh vector holding the elements of list `xs`, in order.

- **Parameters:** `xs` — a proper list.
- **Returns:** a new vector sized `(length xs)`.

```lisp
(vector->list (list->vector (list 10 20 30)))  ; => (10 20 30)
```

**Note:** vectors print as an opaque `[ptr ...]` — always round-trip through
`vector->list` to inspect contents at the REPL.

#### `(vector-fill! v x)`

Sets every slot of `v` to `x` in place.

- **Parameters:** `v` — a vector, mutated in place. `x` — the fill value.
- **Returns:** `v`.

```lisp
(let v (make-vector 3 0))
(vector-fill! v 9)
(vector->list v)  ; => (9 9 9)
```

#### `(vector-copy v)`

Returns a fresh vector with the same elements as `v` (shallow copy — mutating
the copy does not affect the original).

- **Parameters:** `v` — a vector.
- **Returns:** a new vector of the same length.

```lisp
(let v (vector 1 2 3))
(let c (vector-copy v))
(vector-set! c 0 99)
(list (vector->list v) (vector->list c))  ; => ((1 2 3) (99 2 3))
```

#### `(vector-for-each f v)`

Calls `(f element)` for each element of `v`, in order, for side effect.

- **Parameters:** `f` — one-argument procedure. `v` — a vector.
- **Returns:** `nil`.

```lisp
(let acc nil)
(vector-for-each (fn (x) (set acc (cons x acc))) (vector 1 2 3))
acc  ; => (3 2 1)
```

#### `(vector-map f v)`

Returns a fresh vector of `(f element)` for each element of `v`.

- **Parameters:** `f` — one-argument procedure. `v` — a vector.
- **Returns:** a new vector, same length as `v`.

```lisp
(vector->list (vector-map (fn (x) (* x x)) (vector 1 2 3 4)))  ; => (1 4 9 16)
```

#### `(matrix-fill! m x)`

Sets every cell of `m` to `x` in place, row-major.

- **Parameters:** `m` — a matrix, mutated in place. `x` — the fill value.
- **Returns:** `m`.

```lisp
(let m (make-matrix 2 2 0))
(matrix-fill! m 7)
(list (matrix-ref m 0 0) (matrix-ref m 1 1))  ; => (7 7)
```

#### `(matrix-for-each f m)`

Calls `(f cell)` for each cell of `m` in row-major order, for side effect.

- **Parameters:** `f` — one-argument procedure. `m` — a matrix.
- **Returns:** `nil`.

```lisp
(let m (make-matrix 2 2 0))
(matrix-set! m 0 0 1) (matrix-set! m 0 1 2)
(matrix-set! m 1 0 3) (matrix-set! m 1 1 4)
(let acc nil)
(matrix-for-each (fn (x) (set acc (cons x acc))) m)
acc  ; => (4 3 2 1)
```

#### `(matrix-map f m)`

Returns a fresh matrix of `(f cell)` for each cell of `m`, preserving
dimensions.

- **Parameters:** `f` — one-argument procedure. `m` — a matrix.
- **Returns:** a new matrix, same `rows`/`cols` as `m`.

```lisp
(let m (make-matrix 2 2 0))
(matrix-set! m 0 0 1) (matrix-set! m 0 1 2)
(matrix-set! m 1 0 3) (matrix-set! m 1 1 4)
(let out (matrix-map (fn (x) (* x 10)) m))
(list (matrix-ref out 0 0) (matrix-ref out 0 1) (matrix-ref out 1 0) (matrix-ref out 1 1))
; => (10 20 30 40)
```

#### `(hash-values h)`

Returns the list of values in `h`, in the same order as `(hash-keys h)`.

- **Parameters:** `h` — a hash table.
- **Returns:** a new list of values.

```lisp
(let h (make-hash-table))
(hash-set! h "a" 1) (hash-set! h "b" 2)
(hash-keys h)   ; => ("b" "a")
(hash-values h) ; => (2 1)
```

**Note:** iteration order is insertion-reversed in the current hash-table
implementation (newest key first), not insertion order — `hash-values` just
mirrors whatever order `hash-keys` gives.

#### `(hash->alist h)`

Returns a list of `(key . value)` pairs for every live entry in `h`.

- **Parameters:** `h` — a hash table.
- **Returns:** a new alist.

```lisp
(let h (make-hash-table))
(hash-set! h "a" 1) (hash-set! h "b" 2)
(hash->alist h)  ; => (("b" . 2) ("a" . 1))
```

#### `(alist->hash al)`

Builds a fresh hash table from an alist of `(key . value)` pairs. Later pairs
overwrite earlier ones for the same key.

- **Parameters:** `al` — a list of `(key . value)` pairs.
- **Returns:** a new hash table.

```lisp
(let h (alist->hash (list (cons "x" 1) (cons "y" 2))))
(list (hash-ref h "x") (hash-ref h "y"))  ; => (1 2)

(let h2 (alist->hash (list (cons "x" 1) (cons "x" 2))))
(hash-ref h2 "x")  ; => 2
```

#### `(hash-for-each f h)`

Calls `(f key value)` for each live entry in `h`.

- **Parameters:** `f` — two-argument procedure. `h` — a hash table.
- **Returns:** `nil`.

```lisp
(let h (make-hash-table))
(hash-set! h "a" 1) (hash-set! h "b" 2)
(let acc nil)
(hash-for-each (fn (k v) (set acc (cons (cons k v) acc))) h)
acc  ; => (("a" . 1) ("b" . 2))
```

---

### `core/55-util.lsp` — small definition/sequencing utilities

Loads after the higher-order functions (50) and before strings (60). Both
entries are bootstrapped by hand with `(set name (mac ...))` — not
`defmacro` — because they're needed before `defmacro` exists in the load
order; quasiquote is technically available by this point but the expansions
are simple enough to build with `list`/`cons` directly, matching the 40-ctrl
style.

#### `(prog1 first . rest)`

Evaluates `first`, then every form in `rest` in order (for effect), and
returns `first`'s value regardless of what `rest` computes. Implemented by
binding `first`'s value to a gensym temp, running `rest`, then yielding the
temp — so `rest` can't accidentally shadow or clobber the return value.

- **Parameters:** `first` — evaluated and captured as the return value. `rest` — zero or more forms evaluated after, for side effect only.
- **Returns:** the value of `first`.

```lisp
(prog1 1 2 3)  ; => 1

(let x 0)
(prog1 (set x (+ x 1)) (set x (+ x 100)))  ; => 1
x  ; => 101
```

#### `(defvar name value)`

Defines a global `name` bound to `value` only if `name` is currently unbound —
so a value set earlier (by user config or a previous load) survives a later
library reload. Uses the host `bound?` primitive, which reports `nil` as
unbound-vs-bound correctly (a global holding `nil` still counts as bound).

- **Parameters:** `name` — an unquoted symbol. `value` — the value to bind if `name` is unbound.
- **Returns:** the (possibly pre-existing) binding of `name`.

```lisp
(defvar myvar 42)
myvar  ; => 42

(let already 5)
(defvar already 999)
already  ; => 5
```

---

### `core/60-str.lsp` — string & format

Char-level primitives (`string-length`, `string-ref`, `substring`,
`string-append`, `number->string`, `string->number`, `char->string`) are host
primitives — Fe has no way to index a string from Lisp. This module builds
concatenation, joining, splitting, `printf`-style formatting, and char-class
predicates on top.

#### `(str a b ...)`

Concatenates the stringified form of every argument. An alias for
`string-append`, which already stringifies each argument (numbers via
`%.7g`, symbols by name, strings raw).

- **Parameters:** `a b ...` — any values.
- **Returns:** a single string.

```lisp
(str "a" 1 "b" 'sym)  ; => "a1bsym"
```

#### `(join xs sep)`

Joins the stringified elements of list `xs` with `sep` between each pair.

- **Parameters:** `xs` — a list. `sep` — a string inserted between elements.
- **Returns:** a string; `""` if `xs` is `nil`.

```lisp
(join (list 1 2 3) ", ")  ; => "1, 2, 3"
(join nil ",")            ; => ""
```

#### `(split s sep)`

Splits `s` on the first character of `sep`, returning the pieces as a list of
strings. Thin wrapper over the host `string-split` primitive (single O(n)
pass) — a hand-rolled `string-ref` scanning loop would be O(n²) since
`string-ref` restringifies the object each call.

- **Parameters:** `s` — the string to split. `sep` — a string whose first character is the delimiter; if empty, no split occurs.
- **Returns:** a list of substrings.

```lisp
(split "a,b,c" ",")  ; => ("a" "b" "c")
(split "abc" "")     ; => ("abc")
```

**Note:** only the *first character* of `sep` is used as the delimiter —
`(split "a,b;c" ",;")` splits only on `,`, not on either character.

#### `(format fmt . args)`

`printf`-style string formatting. Scans `fmt` for `%`-directives and splices
in `args` in order.

- **Parameters:** `fmt` — format string with `%d`/`%u` (decimal), `%x` (hex), `%c` (char code → character), `%s` (stringify anything), `%%` (literal `%`). `args` — values consumed left to right, one per directive (except `%%`).
- **Returns:** the formatted string.

```lisp
(format "%d-%u-%x-%c-%s-%%" 10 20 255 65 "hi")  ; => "10-20-ff-A-hi-%"
```

**Note:** an unrecognized directive (e.g. `%q`) is not an error — it's echoed
back literally as `%` followed by the directive character, and does not
consume an argument: `(format "%q" 1)` => `"%q"`.

#### `(char-whitespace? c)`

Tests whether char code `c` is space, tab, newline, or carriage return.

- **Parameters:** `c` — a char code (as returned by `string-ref`).
- **Returns:** truthy (`t`) or `nil`.

```lisp
(list (char-whitespace? 32) (char-whitespace? 65))  ; => (t nil)
```

#### `(char-digit? c)`

Tests whether char code `c` is ASCII `'0'`–`'9'`.

- **Parameters:** `c` — a char code.
- **Returns:** truthy or `nil`.

```lisp
(list (char-digit? 48) (char-digit? 57) (char-digit? 58))  ; => (t t nil)
```

#### `(char-alpha? c)`

Tests whether char code `c` is ASCII `'A'`–`'Z'` or `'a'`–`'z'`.

- **Parameters:** `c` — a char code.
- **Returns:** truthy or `nil`.

```lisp
(list (char-alpha? 65) (char-alpha? 97) (char-alpha? 48))  ; => (t t nil)
```

#### `(char-alphanumeric? c)`

Tests whether char code `c` is a letter or digit (`char-alpha?` or
`char-digit?`).

- **Parameters:** `c` — a char code.
- **Returns:** truthy or `nil`.

```lisp
(list (char-alphanumeric? 65) (char-alphanumeric? 48) (char-alphanumeric? 32))
; => (t t nil)
```

---

### `core/65-strtool.lsp` — string & char toolkit

Pure Lisp over the host string primitives. Case conversion, fixed-cell-grid
layout helpers (`pad-left`/`pad-right`/`string-repeat`), and the
prefix/suffix/contains tests that knEmacs and cart authoring reach for. Loads
after 60-str (which it builds on) and before 70-sort.

#### `(char-upcase c)`

Shifts a lowercase `a`–`z` char code up by 32 (to uppercase); passes any other
code through unchanged.

- **Parameters:** `c` — a char code.
- **Returns:** a char code.

```lisp
(list (char-upcase 97) (char-upcase 65))  ; => (65 65)
```

#### `(char-downcase c)`

Shifts an uppercase `A`–`Z` char code down by 32 (to lowercase); passes any
other code through unchanged.

- **Parameters:** `c` — a char code.
- **Returns:** a char code.

```lisp
(list (char-downcase 65) (char-downcase 97))  ; => (97 97)
```

#### `(string-upcase s)`

Returns a copy of `s` with every `a`–`z` character upshifted to uppercase;
non-letters pass through unchanged.

- **Parameters:** `s` — a string.
- **Returns:** a new string.

```lisp
(string-upcase "Hello, World!")  ; => "HELLO, WORLD!"
```

#### `(string-downcase s)`

Returns a copy of `s` with every `A`–`Z` character downshifted to lowercase;
non-letters pass through unchanged.

- **Parameters:** `s` — a string.
- **Returns:** a new string.

```lisp
(string-downcase "Hello, World!")  ; => "hello, world!"
```

#### `(string-repeat s n)`

Returns `s` concatenated to itself `n` times.

- **Parameters:** `s` — a string. `n` — repeat count; `n <= 0` yields `""`.
- **Returns:** a new string.

```lisp
(string-repeat "ab" 3)   ; => "ababab"
(string-repeat "ab" 0)   ; => ""
(string-repeat "ab" -2)  ; => ""
```

#### `(pad-left s width . rest)`

Prepends copies of a one-character pad string to `s` until it reaches
`width`. If `s` is already `>= width`, it's returned unchanged — this never
truncates.

- **Parameters:** `s` — the string to pad. `width` — target length. `rest` — optional pad character as a one-character string; defaults to `" "`. Raises if the pad string is not exactly one character.
- **Returns:** the padded (or unchanged) string.

```lisp
(pad-left "7" 3 "0")   ; => "007"
(pad-left "hello" 3)   ; => "hello"
(pad-left "x" 4)       ; => "   x"
(pad-left "x" 4 "ab")  ; => kec: pad-left: pad must be one character
```

#### `(pad-right s width . rest)`

Appends copies of a one-character pad string to `s` until it reaches `width`.
Same no-truncation and one-character-pad rules as `pad-left`.

- **Parameters:** `s` — the string to pad. `width` — target length. `rest` — optional pad character as a one-character string; defaults to `" "`.
- **Returns:** the padded (or unchanged) string.

```lisp
(pad-right "hi" 5 "-")  ; => "hi---"
```

#### `(string-prefix? s affix)`

Tests whether `s` starts with `affix`.

- **Parameters:** `s` — the string to test. `affix` — the prefix to look for.
- **Returns:** truthy or `nil`. An empty `affix` is always a match; an `affix` longer than `s` never matches.

```lisp
(list (string-prefix? "hello" "he") (string-prefix? "hello" "")
      (string-prefix? "hi" "hello") (string-prefix? "hello" "xo"))
; => (t t nil nil)
```

#### `(string-suffix? s affix)`

Tests whether `s` ends with `affix`. Same empty/too-long edge rules as
`string-prefix?`.

- **Parameters:** `s` — the string to test. `affix` — the suffix to look for.
- **Returns:** truthy or `nil`.

```lisp
(list (string-suffix? "hello" "lo") (string-suffix? "hello" "")
      (string-suffix? "hi" "hello"))
; => (t t nil)
```

#### `(string-contains? s needle)`

Tests whether `needle` occurs anywhere in `s`. Built on the host
`string-search` primitive.

- **Parameters:** `s` — the haystack. `needle` — the substring to search for.
- **Returns:** truthy or `nil`. An empty `needle` always matches (search matches at position 0).

```lisp
(list (string-contains? "hello world" "wor") (string-contains? "hello" "")
      (string-contains? "hello" "z"))
; => (t t nil)
```

---

### `core/70-sort.lsp` — stable, iterative merge sort

#### `(sort xs less?)`

Returns a new list with the elements of `xs` ordered by the binary predicate
`less?` (`(less? a b)` truthy means `a` should come before `b`). Implemented
as a bottom-up iterative merge sort: seed each element as a length-1 run, then
repeatedly merge adjacent runs — doubling run length each pass — until one run
remains. Every loop is a `while`, so sort depth doesn't grow with list length
and can't exhaust the bounded GC root stack the way a recursive merge sort
would. Does not mutate the input list.

- **Parameters:** `xs` — a list (possibly `nil`). `less?` — two-argument predicate defining the order.
- **Returns:** a new, sorted list.

```lisp
(sort (list 5 3 1 4 2) (fn (a b) (< a b)))  ; => (1 2 3 4 5)
(sort nil (fn (a b) (< a b)))                ; => nil

(let xs (list 3 1 2))
(sort xs (fn (a b) (< a b)))
xs  ; => (3 1 2)   -- original list untouched
```

**Note:** verified stable — sorting `(1 . "a") (1 . "b") (0 . "c") (1 . "d") (0 . "e")`
by `car` only yields cdrs `("c" "e" "a" "b" "d")`: the two `0`-keyed elements
keep their original relative order (`c` before `e`), as do the three `1`-keyed
elements (`a` before `b` before `d`). The merge step takes from the left run
first on a tie, which is what preserves this.
