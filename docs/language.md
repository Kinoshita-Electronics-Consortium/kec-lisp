---
title: Language Reference
description: The KEC Lisp kernel, the standard library (core/), and the C host primitives this repo ships.
---

Reference for KEC Lisp: the kernel, the standard library (`core/`), and the C
primitives (`host/`) this repo ships. The KN-86 device primitives live in the
firmware, not here.

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
- **Quote.** `'x` ≡ `(quote x)`. There is no quasiquote/unquote — macros build
  expansions with `list`/`cons`/`append`.

Booleans are not a type: `nil` is false, everything else (including `0` and
`""`) is true. Predicates return a truthy value or `nil`.

---

## 2. The kernel

KEC Lisp's kernel is rxi's [Fe](https://github.com/rxi/fe), vendored. Most new
things get added in Core (Lisp) or as a C primitive; the kernel itself gets
patched when there's a reason to. It has 26 primitives:

```
let  set  if  fn  mac  while  quote  and  or  do
cons  car  cdr  setcar  setcdr  list  not  is  atom  print
<  <=  +  -  *  /
```

(KEC names assignment `set` rather than Fe's `=`, which leaves `=` free to mean
equality.)

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
| `(is a b)` | Equality: numbers by value, strings structurally, pairs and other atoms by identity. |
| `(atom x)` | `x` is not a pair. |
| `(print …)` | Write args to stdout + newline. |
| `< <= + - * /` | Numeric (variadic for arithmetic). |

A few things the kernel doesn't have, that Core or the host fill in:

- No `define`/`defun`/`defmacro`/`cond`/`>` — Core adds these. `=` isn't a
  kernel primitive; it's value-equality from Core (assignment is `set`).
- `is` compares lists by identity, not contents — `(is (list 1) (list 1))` is
  `nil`. Compare element by element.
- The GC root stack is small and fixed (256 by default, larger on desktop
  builds), so recursion depth is bounded; long library traversals use `while`.
- No tail-call optimization, no `eval` from Lisp, no vectors/hash-tables/records.

---

## 3. The standard library (Core)

Written in KEC Lisp (with a few C helpers: `type-of`, `mod`, `gensym`, the
string ops). Loaded before your code runs.

### 3.1 `def` — definitions
| Form | Expands to |
|---|---|
| `(defn name (params…) body…)` | `(set name (fn (params…) body…))` |
| `(defmacro name (params…) body…)` | `(set name (mac (params…) body…))` |
| `(define name value)` | `(set name value)` |
| `(define (f args…) body…)` | `(set f (fn (args…) body…))` (Scheme-style sugar) |

Each form **returns the value it defines** — the function, macro, or value — not
`nil`. (Bare `set` returns `nil`; these wrap it so definitions chain and the REPL
echoes something useful.)

### 3.2 `list` — list & sequence
`nth` `length` `reverse` `append` `last` `member` `assoc` `take` `drop` `range`.
All iterative. `(range a b)` → `(a … b-1)`; `(nth xs i)` → `nil` past the end;
`(member x xs)` / `(assoc k alist)` → the matching tail/pair or `nil`.

### 3.3 `cmp` — comparison
`=` `==` `/=` `>` `>=` `zero?` `positive?` `negative?` `min` `max` (variadic).
`=`, `==`, and `is` are the same value comparison; `/=` negates it.

### 3.4 `pred` — predicates
`nil?` `pair?` `even?` `odd?` `number?` `symbol?` `string?` `fn?`. The four type
tests use the host `type-of` primitive.

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

### 3.8 `sort` — ordering
`(sort xs less?)` → a new list with the elements of `xs` ordered by the binary
predicate `less?` (`(less? a b)` truthy when `a` precedes `b`). The input is not
mutated. It's a **stable** sort — equal elements keep their original relative
order — implemented as an iterative, bottom-up merge sort, so a long list (1000+
elements) won't exhaust the GC root stack.

---

## 4. C primitives (host)

C functions that only need the C library. Two profiles: `FULL` (used by the CLI)
adds the file and system primitives; `SANDBOX` leaves them out.

| Group | Primitives | Profile |
|---|---|---|
| Reflection | `type-of` `gensym` | both |
| Math | `mod` `floor` `ceil` `round` `abs` `sqrt` `pow` | both |
| String | `string-length` `string-ref` `substring` `string-append` `char->string` `number->string` `string->number` `symbol->string` `string->symbol` | both |
| I/O | `princ` `newline` `repr` | both |
| Sys | `rand` `rand-int` `clock` | both |
| Control | `try` `apply` `read-string` | both |
| File/Sys | `load` `slurp` `spit` `spit-append` `file-exists?` `list-dir` `getenv` `args` `exit` | **FULL only** |

- `(type-of x)` → `:pair`/`:nil`/`:number`/`:symbol`/`:string`/`:fn`/`:macro`/`:prim`/`:cfunc`/`:ptr`.
- `(number->string n [radix])` — radix defaults to 10; 2/8/16 supported.
- `(try thunk)` → the value of `(thunk)` on success, or the pair
  `(:error . "message")` if it raised — `car` is the `:error` symbol (so failure
  is recognizable via `(car r)`) and `cdr` is the captured error string.
  `check-err` in the test harness keys off the `:error` car.
- `(apply f arglist)` calls `f` with the elements of `arglist` as its arguments
  — `(apply + (list 1 2 3))` → `6`. `f` may be a closure, a host primitive, or a
  kernel primitive; `arglist` may be `nil` (call with no args).
- `(read-string s)` parses the **first** s-expression of `s` and returns it
  **without evaluating** — `(read-string "(1 2 3)")` → the list `(1 2 3)`,
  `"42"` → `42`, `"foo"` → the symbol `foo`. It is the reader, not `eval`: the
  form is returned as data and nothing runs (so reading a `(spit …)` form writes
  no file). Empty input → `nil`.
- `(load "path")` reads and evaluates a file in the current context.
- `(spit path value)` writes `value` (stringified the writer's way, like
  `princ`/`str`) to `path`, creating or **overwriting** it. `(spit-append path
  value)` appends instead, creating the file if absent. Both return a truthy
  value on success and raise a catchable error (never `exit`) on an I/O failure.
  Round-trips with `slurp`. **FULL only** — a sandboxed context cannot write
  files.
- `(file-exists? path)` → truthy if `path` exists, else `nil`. `(list-dir path)`
  → a list of the directory's entry names (`.` and `..` excluded; order
  unspecified), raising a catchable error if the directory can't be opened.
  `(getenv name)` → the environment variable's value as a string, or `nil` if
  unset. All three are **FULL only**.

---

## 5. Evaluation & errors

- **Application** evaluates the operator, then arguments left-to-right.
- **Macros** receive unevaluated forms; the expansion replaces the call site
  and is re-evaluated.
- **Errors** route through `fe_error`. The runtime installs a recovery handler
  that unwinds to the nearest guard (the REPL prompt, a script boundary, or a
  `(try …)`) instead of exiting. `(try …)` is the Lisp-visible catch: it returns
  the thunk's value on success, or `(:error . "message")` on failure — detect a
  failure with `(and (pair? r) (is (car r) ':error))` and read the message from
  `(cdr r)`.

---

## 6. Quick reference

1. Bind with `define` / `defn` / `let`; mutate with `set`; compare with `=` / `==`.
2. List equality is element-wise — `is` / `=` compare pairs by identity.
3. Core is iterative; for your own deep recursion prefer `while` / `fold-left`
   (the GC-root stack is bounded, though generous on desktop builds).
4. Numbers are single floats; mind ±2²⁴ and exact-integer expectations.
