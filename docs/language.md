# KEC Lisp — Language Reference

This is the implementer-and-author reference for the standalone KEC Lisp
distribution. It documents the Fe Kernel surface (Layer 0), the KEC Core
prelude (Layer 1), and the portable host stdlib (Layer 2) that this repository
ships. The device FFI (NoshAPI) is downstream and documented separately.

The canonical, prescriptive standard is the KN-86 *KEC Lisp Language Standard*
(ADR-0037). Where this implementation deviates from the standard for a concrete
reason, it is flagged **⚠ deviation** below.

---

## 1. Lexical structure

- **S-expressions.** Atoms or parenthesized lists. `(a . b)` is a cons cell.
- **Comments.** `;` to end of line. No block comments.
- **Numbers.** `fe_Number` is a single-precision `float`. `123`, `-4.5`, `3.14`.
  Integers are exact only within ±2²⁴.
- **Strings.** `"text"`, immutable. `\"` and `\\` escapes in the reader.
- **Symbols.** `foo`, `kebab-case`, `+`, `<=`, `:keyword`. Case-sensitive.
  `:keyword`s are ordinary symbols (there is no keyword type).
- **`nil`.** The empty list and the only false value. Read as the nil sentinel,
  not a symbol.
- **Quote.** `'x` ≡ `(quote x)`. There is **no quasiquote/unquote** — macros
  build expansions with `list`/`cons`/`append`.

Booleans are not a type: `nil` is false, everything else (including `0` and
`""`) is true. Predicates return a truthy value or `nil`.

---

## 2. Fe Kernel — the 26 primitives (Layer 0, frozen)

The kernel is vendored `rxi/fe` 1.0 and is **never extended or forked**. New
capability comes through Core (KEC Lisp) or the Stdlib (a bound C function).

```
let  set  if  fn  mac  while  quote  and  or  do
cons  car  cdr  setcar  setcdr  list  not  is  atom  print
<  <=  +  -  *  /
```

> **KEC kernel change.** Upstream Fe names assignment `=`. KEC renames it to
> `set`, which frees `=` to mean equality in Core (standard §4.1). The
> primitive is otherwise unchanged.

| Form | Meaning |
|---|---|
| `(let sym val)` | Bind `sym`. Inside a body → a local for the rest of that body; at the top level → a global. |
| `(set sym val)` | Assignment to an existing binding (or a top-level global). |
| `(if c a b…)` | Conditional; supports cond-style chaining `(if c1 t1 c2 t2 else)`. |
| `(fn (params…) body…)` | Lambda (lexical closure). `(fn (a . rest) …)` and `(fn args …)` bind variadic/rest args. |
| `(mac (params…) body…)` | Macro; args unevaluated, expansion re-evaluated. |
| `(while c body…)` | Loop while `c` is truthy; returns `nil`. |
| `(quote x)` / `'x` | Suppress evaluation. |
| `(and …)` / `(or …)` | Short-circuit. |
| `(do …)` | Sequence; returns last. |
| `cons car cdr setcar setcdr list` | Pair construction / access / mutation. |
| `(not x)` | `x` is `nil`. |
| `(is a b)` | Equality: numbers by value, strings structurally, **pairs and other atoms by identity**. |
| `(atom x)` | `x` is not a pair. |
| `(print …)` | Write args to stdout + newline. |
| `< <= + - * /` | Numeric (variadic for arithmetic). |

Notable kernel realities:

- **No `define`/`defun`/`defmacro`/`cond`/`>`** — Core supplies these. `=` is
  not a kernel primitive in KEC; it is Core value-equality (assignment is `set`).
- **`is` is not structural over lists.** `(is (list 1) (list 1))` → `nil`.
  Compare element-wise.
- **GC root stack is small and fixed** (256 default; raised on desktop builds).
  Recursion depth is bounded by it, so long *library* traversals use `while`.
- **No TCO, no `eval` from Lisp, no vectors/hash-tables/records.**

---

## 3. KEC Core — the prelude (Layer 1, KEC Lisp)

Loaded into every context before user code. Authored in KEC Lisp over the
kernel (plus `type-of`/`mod`/`gensym`/string leaves from the host).

### 3.1 `def` — definitions
| Form | Expands to |
|---|---|
| `(defn name (params…) body…)` | `(= name (fn (params…) body…))` |
| `(defmacro name (params…) body…)` | `(= name (mac (params…) body…))` |
| `(define name value)` | `(= name value)` |
| `(define (f args…) body…)` | `(= f (fn (args…) body…))` (Scheme-style sugar) |

### 3.2 `list` — list & sequence
`nth` `length` `reverse` `append` `last` `member` `assoc` `take` `drop` `range`.
All iterative (bounded depth). `(range a b)` → `(a … b-1)`; `(nth xs i)` → `nil`
past the end; `(member x xs)` / `(assoc k alist)` → the matching tail/pair or
`nil`.

### 3.3 `cmp` — comparison
`=` `==` `/=` `>` `>=` `zero?` `positive?` `negative?` `min` `max` (variadic).
`=`, `==`, and `is` are the same value comparison; `/=` negates it.

> **Note on `=` (standard §4.1).** The standard names equality `=`. Upstream Fe
> used `=` for *assignment*, which is the conflict an earlier draft flagged.
> KEC resolves it at the kernel: assignment is `set`, so `=` is free for
> equality and this implementation **conforms** to §4.1 directly.

### 3.4 `pred` — predicates
`nil?` `pair?` `even?` `odd?` `number?` `symbol?` `string?` `fn?`. The four tag
tests use the host `type-of` primitive (standard §4.7).

### 3.5 `ctrl` — control macros
`when` `unless` `cond` `case` `let*` `letrec` `dotimes` `dolist` `begin`.

```lisp
(cond ((< n 0) 'neg) ((is n 0) 'zero) (else 'pos))
(case k (1 'one) ((2 3) 'few) (else 'many))   ; value or list of values
(let* ((a 2) (b (* a 3))) (+ a b))
(dotimes (i n) …)        (dolist (x xs) …)
```

### 3.6 `hof` — higher-order
`map` `filter` `remove` `fold-left` `fold-right` `for-each` `find` `any?`
`every?` `count`. All iterative.

### 3.7 `str` — string & format
`str` (variadic stringify-concat) `join` `split` `format`. `format` directives:
`%d`/`%u` decimal, `%x` hex, `%c` char code, `%s` any, `%%` literal.

---

## 4. Host stdlib (Layer 2, portable)

Bound C primitives that need only the C library. Two capability profiles
demonstrate "capability is the binding-set": `FULL` (the CLI) adds file/sys
primitives on top of `SANDBOX`.

| Group | Primitives | Profile |
|---|---|---|
| Reflection | `type-of` `gensym` | both |
| Math | `mod` `floor` `ceil` `round` `abs` `sqrt` `pow` | both |
| String leaves | `string-length` `string-ref` `substring` `string-append` `char->string` `number->string` `string->number` `symbol->string` `string->symbol` | both |
| I/O | `princ` `newline` `repr` | both |
| Sys | `rand` `rand-int` `clock` | both |
| Control | `try` | both |
| File/Sys | `load` `slurp` `args` `exit` | **FULL only** |

- `(type-of x)` → `:pair`/`:nil`/`:number`/`:symbol`/`:string`/`:fn`/`:macro`/`:prim`/`:cfunc`/`:ptr`.
- `(number->string n [radix])` — radix defaults to 10; 2/8/16 supported.
- `(try thunk)` → the value of `(thunk)`, or `:error` if it raised. The
  primitive the test harness's `check-err` is built on.
- `(load "path")` reads and evaluates a file in the current context.

---

## 5. Evaluation & errors

- **Application** evaluates the operator, then arguments left-to-right.
- **Macros** receive unevaluated forms; the expansion replaces the call site
  and is re-evaluated.
- **Errors** route through `fe_error`. The standalone runtime installs a
  recovery handler that unwinds to the nearest guard (the REPL prompt, a script
  boundary, or a `(try …)`) instead of exiting. `(try …)` is the Lisp-visible
  catch.

---

## 6. Quick reference

1. Bind with `define` / `defn` / `let`; mutate with `set`; compare with `=` / `==`.
2. List equality is element-wise — `is` / `=` are identity on pairs.
3. Core is iterative; for your own deep recursion prefer `while` / `fold-left`
   (the GC-root stack is bounded, though generous on desktop builds).
4. Numbers are single floats; mind ±2²⁴ and exact-integer expectations.
