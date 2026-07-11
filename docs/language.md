---
title: Language Reference
description: Syntax, values, evaluation, standard library, and host primitives for KEC Lisp.
---

KEC Lisp is a small Lisp built on the Fe kernel, a Lisp-authored standard
library called Core, and a portable C host layer. This page is the day-to-day
language reference: syntax first, then evaluation rules, built-in forms, Core,
host primitives, errors, and limits.

```lisp
(define (squares n)
  (map (fn (x) (* x x)) (range 1 (+ n 1))))

(squares 5)  ; => (1 4 9 16 25)
```

## Language Layers

| Layer | What it provides | Defined in |
|---|---|---|
| Kernel | Reader, evaluator, arena/GC, and 26 compiled-in primitives. | `kernel/` |
| Core | Definition macros, control macros, list helpers, predicates, alists, higher-order functions, strings, and sort. | `core/*.lsp` |
| Runtime / host | Portable C primitives for errors, reflection, math, strings, I/O, loading, and file/system access. | `runtime/`, `host/` |

The KN-86 device primitives live in the firmware, not this repository.

## Syntax

KEC Lisp programs are made of s-expressions: atoms or parenthesized lists. A
list in call position is evaluated as a function, macro, special form, or host
primitive call.

```lisp
(+ 1 2 3)
(print "hello")
(map (fn (x) (* x x)) (range 1 6))
```

| Syntax | Meaning |
|---|---|
| `; comment` | Comment to the end of the line. There are no block comments. |
| `123`, `-4.5`, `3.14` | Numbers. The runtime stores them as single-precision floats. |
| `"text"` | String literal. The reader supports `\"` and `\\` escapes. |
| `foo`, `kebab-case`, `+`, `:tag` | Symbols. Symbols are case-sensitive; `:tag` is an ordinary symbol, not a separate keyword type. |
| `nil` | The empty list and the only false value. |
| `(a . b)` | A single cons pair. |
| `'x` | Reader sugar for `(quote x)`. |
| `` `x `` | Reader sugar for `(quasiquote x)`. |
| `,x`, `,@x` | Unquote and unquote-splicing inside quasiquote. |

### Punctuation Characters

KEC Lisp uses **21 distinct punctuation characters**. Ten are recognized by the
reader (`read_` in `kernel/fe.c`) as structure; eleven appear inside the names of
kernel primitives and Core definitions you have to type. `#`, `&`, `^`, `$`,
`~`, and `|` are *not* used — none are reader-special and none appear in any
standard name.

**Reader / structural** — handled specially by the reader:

| Char | Role | Word-form alternative |
|---|---|---|
| `(` `)` | List delimiters. | None. |
| `"` | String-literal delimiter. | None. |
| `.` | Dotted pair, rest/variadic params `(fn (a . rest) ...)`, decimal point in numbers. | None. |
| `;` | Line comment to end of line. | None — the only comment syntax. |
| `\` | String escape (`\"`, `\\`, `\n`, `\r`, `\t`), inside strings only. | None for escapes. |
| `'` | Quote sugar. | `(quote x)` |
| `` ` `` | Quasiquote sugar. | `(quasiquote x)` |
| `,` | Unquote sugar. | `(unquote x)` |
| `@` | Only as `,@` — unquote-splicing. | `(unquote-splicing x)` |

**Identifier / operator** — part of names you must type:

| Char | Required for | Word-form alternative |
|---|---|---|
| `<` | `<`, `<=` — kernel ordering primitives. | None. |
| `?` | The predicate family — `nil?`, `pair?`, `number?`, `bound?`, `even?`, ... | None. |
| `>` | `>`, `>=`, and `->` converters (`number->string`, `char->string`, ...). | None. |
| `=` | `=`, `==`, `/=`, `<=`, `>=`. | `is` covers equality; `<=`/`>=` still need it. |
| `+` `-` `*` `/` | Arithmetic primitives; `-` is also the kebab-case separator in most multi-word names. | None. |
| `:` | Keyword-style symbols, notably `type-of` results (`:number`, `:pair`, ...). | None. |
| `!` | The bang-mutation suffix — `vector-set!`, `matrix-set!`, `blob-set!`, `hash-set!`, `hash-del!`, `vector-fill!`, `matrix-fill!`, `set-seed!`. | None. |
| `%` | The private-name prefix for Core internals (`%append`, `%qq`, ...) and the `format` directive character (`%d`, `%x`, ...). | None. |

`<` and `?` have no word-form escape: ordering comparisons and the standard
predicates can only be written with them. Whether a given physical keyboard can
type this whole set is a device/firmware concern, not a language one.

## Values And Truth

`nil` is false. Every other value is true, including `0`, empty strings, empty
symbols, functions, and pairs.

| Value kind | Notes |
|---|---|
| `nil` | Empty list and false value. |
| Number | Single-precision `float`; exact integer expectations are safe only within +/-2^24. |
| String | Immutable and null-terminated by the Fe kernel. |
| Symbol | Interned name. `:name` is a naming convention, not a separate type. |
| Pair / list | Built with `cons` or `list`; a proper list ends in `nil`. |
| Function | Lexical closure made by `fn` or `defn`. |
| Macro | Expansion function made by `mac` or `defmacro`; receives unevaluated forms. |
| Primitive | Kernel primitive or C function bound through the host/FFI layer. |

Equality has two useful levels:

| Form | Use |
|---|---|
| `(is a b)` | Kernel equality: numbers by value, strings structurally, pairs and most other atoms by identity. |
| `(= a b)` / `(== a b)` | Core aliases for `is`; good for scalar comparison. |
| `(equal? a b)` | Structural pair/list comparison (iterative down the spine, so long lists are GC-stack-safe). |

## Evaluation

Evaluation follows the usual Lisp shape:

1. A literal number, string, or `nil` evaluates to itself.
2. A symbol evaluates to its current binding. **A never-bound symbol evaluates
   to `nil`, not an error** — the kernel does not signal "unbound variable" on
   read. A real `nil` value and no binding at all therefore look identical from
   evaluation; use `(bound? 'name)` to tell them apart (see
   [Fe Kernel - Internals](/kec-lisp/fe-kernel/#symbols)). Calling a never-bound
   symbol *does* error, since `nil` is not callable.
3. A list evaluates its operator, then applies it according to what the operator
   is.
4. Function and C primitive arguments are evaluated left to right before the
   call.
5. Macros receive their arguments unevaluated; the macro result replaces the
   call and is evaluated again.
6. Special forms such as `if`, `let`, `set`, `fn`, `mac`, `quote`, `and`, `or`,
   `while`, and `do` control their own evaluation rules.

`(read-string s)` parses one s-expression and returns it as data; it does not
run it. `FULL` contexts also bind Lisp-level `eval`; `SANDBOX` contexts do not.

## Binding And Functions

The kernel provides the small core of binding and callable construction. Core
adds the definition forms most programs use.

| Form | Meaning |
|---|---|
| `(let name value)` | Bind `name`. Inside a body it creates a local for the rest of that body; at the top level it creates a global. Returns `value`. |
| `(set name value)` | Assign an existing binding, or a top-level global. Returns `nil`. |
| `(fn (params...) body...)` | Create a lexical closure. |
| `(fn (a . rest) body...)` | Create a closure with rest arguments. |
| `(fn args body...)` | Bind all arguments as one list. |
| `(mac (params...) body...)` | Create a macro. Arguments are not evaluated before the macro runs. |
| `(define name value)` | Define a value and return it. |
| `(define (name params...) body...)` | Scheme-style function definition. |
| `(defn name (params...) body...)` | Define a function and return it. |
| `(defmacro name (params...) body...)` | Define a macro and return it. |

```lisp
(define greeting "hello")

(defn greet (name)
  (str greeting ", " name))

(defn sum (xs)
  (fold-left + 0 xs))
```

## Control Flow

| Form | Meaning |
|---|---|
| `(if test then else)` | Conditional. Only the selected branch is evaluated. |
| `(if c1 t1 c2 t2 else)` | Cond-style kernel chaining. |
| `(cond (test body...) ... (else body...))` | First truthy test wins. |
| `(case key (value body...) ... (else body...))` | Match `key` against a value or list of values with `member`. |
| `(when test body...)` | Run body when `test` is truthy. |
| `(unless test body...)` | Run body when `test` is false. |
| `(and a b ...)` | Short-circuit AND; returns the last truthy value or `nil`. |
| `(or a b ...)` | Short-circuit OR; returns the first truthy value or `nil`. |
| `(while test body...)` | Loop while `test` is truthy; returns `nil`. |
| `(dotimes (i n) body...)` | Loop `i` from `0` to `n - 1`. |
| `(dolist (x xs) body...)` | Loop over a list. |
| `(do body...)` / `(begin body...)` | Sequence; returns the last value. |
| `(prog1 first rest...)` | Sequence; returns the **first** form's value. |
| `(let* ((name value) ...) body...)` | Sequential local bindings. |
| `(letrec ((name value) ...) body...)` | Mutually recursive local bindings. |

```lisp
(cond
  ((< n 0) 'negative)
  ((is n 0) 'zero)
  (else 'positive))
```

## Data Structures

Pairs and lists are the primary data structure. Use `cons` for one pair and
`list` for proper lists.

| Form | Meaning |
|---|---|
| `(cons a b)` | Allocate a pair. |
| `(car pair)` | Read the first slot. |
| `(cdr pair)` | Read the second slot. |
| `(setcar pair value)` | Mutate the first slot. |
| `(setcdr pair value)` | Mutate the second slot. |
| `(list a b ...)` | Build a proper list. |
| `(nth xs i)` | Element at index `i`, or `nil` past the end. |
| `(length xs)` | List length. |
| `(reverse xs)` | Reversed copy. |
| `(append a b)` | Append two lists. |
| `(take xs n)` / `(drop xs n)` | Prefix or suffix by count. |
| `(range a b)` | Numbers from `a` through `b - 1`. |
| `(member x xs)` | Matching tail, or `nil`. |
| `(assoc key alist)` | Matching pair in an association list, or `nil`. |

Association lists are the built-in record shape:

| Form | Meaning |
|---|---|
| `(get key alist [default])` | Value for `key`, or `default`/`nil`. |
| `(put key value alist)` | Return a new alist with `key` updated. |
| `(has? key alist)` | Truthy when `key` exists. |
| `(keys alist)` / `(values alist)` | Extract keys or values. |
| `(merge a b)` | Return a new alist with `b` overlaid on `a`. |

```lisp
(let user (list (cons 'name "Ada") (cons 'score 42)))
(get 'name user)       ; => "Ada"
(put 'score 99 user)   ; returns a new alist
```

## Standard Library (Core)

Core is written in KEC Lisp and loaded before user code. Its files load in
numeric filename order. This section is a quick day-to-day cheat sheet; for
full signatures, parameters, and worked examples per function, see the
[Core Library Reference](/kec-lisp/core-library/).

### Definitions

| Form | Expands to |
|---|---|
| `(defn name (params...) body...)` | `(do (set name (fn (params...) body...)) name)` |
| `(defmacro name (params...) body...)` | `(do (set name (mac (params...) body...)) name)` |
| `(define name value)` | `(do (set name value) name)` |
| `(define (f args...) body...)` | `(do (set f (fn (args...) body...)) f)` |
| `(defvar name value)` | `(if (bound? 'name) name (do (set name value) name))` |

Each definition form returns the value it defines, which makes REPL output and
definition chaining more useful than bare `set`. `defvar` only assigns when
`name` is currently **unbound**, so a user/config value set earlier—including
`nil`—survives a later library load.

### Lists

| Function | Summary |
|---|---|
| `nth`, `length`, `reverse`, `append`, `last` | Basic list access and construction. |
| `member`, `assoc` | Search lists and alists. |
| `take`, `drop`, `range` | Sequence construction and slicing. |

Core list functions are iterative, which avoids exhausting the bounded GC root
stack on ordinary list work.

### Comparison And Numbers

| Function | Summary |
|---|---|
| `=`, `==`, `/=` | Scalar/identity equality and inequality. |
| `equal?` | Structural list equality. |
| `>`, `>=` | Greater-than comparisons. |
| `zero?`, `positive?`, `negative?` | Numeric predicates. |
| `min`, `max` | Variadic extrema. |

### Predicates

| Function | Summary |
|---|---|
| `nil?`, `pair?` | List shape tests. |
| `even?`, `odd?` | Numeric parity using host `mod`. |
| `number?`, `symbol?`, `string?`, `fn?` | Type tests using host `type-of`. |

### Errors

| Function | Summary |
|---|---|
| `(error message)` | Build an error value, `(:error . message)`. |
| `(error? value)` | Test for that error shape. |
| `(error-message err)` | Read the message from an error value. |

### Error Recovery

Higher-level recovery macros built on the runtime's `try` / `raise` (see
[Errors](#errors-1)). KEC errors carry only a **message** — there is no error
class yet, so `condition-case` dispatch is message-based and re-raises are
message-only (typed/structured errors are a deferred follow-up, ADR-0001).

| Macro | Summary |
|---|---|
| `(unwind-protect body cleanup...)` | Run `body`, then **always** run the cleanup forms — on normal return *and* on a raised error. On error, cleanup runs first, then the error is re-raised (message-only) so an outer handler still sees it. The `save-excursion`-class wrapper primitive. |
| `(ignore-errors body...)` | Evaluate `body`, yielding `nil` on any raised error and the body value otherwise. |
| `(condition-case var bodyform handler...)` | Evaluate `bodyform`. On error, bind `var` to the `(:error . message)` value and run the first handler's body (message-based, catch-all); otherwise return the body value. With no handlers, the result is returned as-is. |

```lisp
(unwind-protect
    (do (open-region) (process))   ; body
  (close-region))                  ; cleanup — runs even if process raises

(condition-case e (parse user-input)
  (e (str "parse failed: " (error-message e))))
```

### Control Macros

| Macro | Summary |
|---|---|
| `when`, `unless` | Conditional bodies. |
| `cond`, `case` | Multi-way branching. |
| `let*`, `letrec` | Sequential and recursive local bindings. |
| `dotimes`, `dolist` | Iteration helpers. |
| `begin` | Alias for `do`. |

These macros expand into forms that bottom out on **frozen kernel primitives
only** — they never emit a call to a shadowable Core function. So redefining a
library name does not silently change a macro: `(case k ...)` keeps working even
if you redefine `member`. See *Load-bearing prelude* below.

### Load-bearing prelude (do not shadow)

`set` and a top-level `let` rebind a global anywhere (see [Binding And
Functions](#binding-and-functions)). That flexibility is real, but a handful of
Core names are **load-bearing**: the runtime and the prelude are built on top of
them. Redefining one is the KEC analog of overriding a standard method that
*must* run (AMOP §4.2.2, "Overriding the Standard Method") — treat it as
prohibited, because on a device there is no debugger to catch the fallout.

- **Never shadow** the frozen kernel primitives (`cons`, `car`, `cdr`, `setcar`,
  `setcdr`, `list`, `is`, `not`, `atom`, `print`, `if`, `let`, `set`, `fn`,
  `mac`, `do`, `while`, `quote`, `and`, `or`, `<`, `<=`, `+`, `-`, `*`, `/`) or
  `gensym`. The macro expanders emit these by name; redefining them corrupts
  every macro — and the runtime enforces it: all 26 raise
  `cannot rebind load-bearing primitive`.
- **Avoid shadowing** the core list/sequence functions the prelude leans on
  (`nth`, `length`, `reverse`, `append`, `member`, `map`). Macro *expansions* no
  longer depend on them, but the rest of Core does.
- **`%`-prefixed names are private.** `%append`, `%case-expand`, `%let*-binds`,
  and friends are internal macro machinery (e.g. `%append` is the load-time
  capture of `append` that quasiquote's `,@` splices through, so shadowing the
  public `append` can't break a backquote). Do not define or rebind `%…` names.

To check what a name currently resolves to, use `(bound? 'name)` and
`(globals "prefix")` (see [Runtime / Host Primitives](#runtime--host-primitives)).

### Quasiquote

Backquote builds data, comma evaluates a subform, and comma-at splices a list:

```lisp
(let x 7)
`(a ,x ,@(list 'b 'c))   ; => (a 7 b c)

(defmacro my-when (test . body)
  `(if ,test (do ,@body) nil))
```

### Higher-Order Functions

| Function | Summary |
|---|---|
| `map`, `filter`, `remove` | Transform and select list elements. |
| `fold-left`, `fold-right` | Reduce a list. |
| `for-each` | Apply a function for side effects. |
| `find`, `any?`, `every?`, `count` | Predicate-based search and counting. |

### Strings And Formatting

| Function | Summary |
|---|---|
| `(str value...)` | Stringify and concatenate values. |
| `(join xs sep)` | Join strings with a separator. |
| `(split s sep)` | Split a string on a separator. |
| `(format fmt args...)` | Format using `%d`, `%u`, `%x`, `%c`, `%s`, and `%%`. |
| `char-whitespace?`, `char-digit?`, `char-alpha?`, `char-alphanumeric?` | Character-class predicates over char codes (as returned by `string-ref`). |

#### String / char toolkit

Built over the host string primitives for case folding, fixed-cell-grid layout,
and substring tests.

| Function | Summary |
|---|---|
| `(char-upcase c)` / `(char-downcase c)` | Shift an `a`–`z` / `A`–`Z` char code; any other code passes through unchanged. |
| `(string-upcase s)` / `(string-downcase s)` | Case-fold every character of `s`. |
| `(pad-left s width [pad])` / `(pad-right s width [pad])` | Pad `s` to `width` with the one-character string `pad` (default `" "`). Empty or multi-character pads raise. Never truncates: an `s` already ≥ `width` is returned unchanged. |
| `(string-repeat s n)` | `s` concatenated `n` times; `n ≤ 0` yields `""`. |
| `(string-prefix? s affix)` / `(string-suffix? s affix)` | Does `s` start / end with `affix`? Empty affix → true; an affix longer than `s` → false. |
| `(string-contains? s needle)` | Truthy if `needle` occurs anywhere in `s` (empty needle → true). |

### Symbol Properties

A side registry for per-symbol metadata (Fe symbols have no property slot).
Named `*-prop` because `get`/`put` already operate on association lists.

| Function | Summary |
|---|---|
| `(put-prop sym key val)` | Store or overwrite property `key` of `sym`; returns `val`. |
| `(get-prop sym key)` | Read the stored value, or `nil` if absent. |

Useful for the kind of per-symbol metadata an editor wants — indentation rules,
docstrings, a `disabled` flag — keyed by symbol identity.

### Sorting

`(sort xs less?)` returns a new stable sorted list. The predicate is called as
`(less? a b)` and should return truthy when `a` belongs before `b`. The input
list is not mutated.

## Runtime / Host Primitives

Runtime and host primitives are C functions registered into a KEC Lisp context.
Two profiles are available: `SANDBOX` gets the portable non-file primitives, and
`FULL` adds loading, file I/O, environment access, process arguments, and exit.
The `kec` CLI uses `FULL`.

| Group | Primitives | Profile |
|---|---|---|
| Reflection | `type-of`, `gensym`, `bound?`, `globals`, `fn-params` | both |
| Math | `mod`, `floor`, `ceil`, `round`, `abs`, `sqrt`, `pow`, `sin`, `cos`, `tan`, `atan2` | both |
| Bitwise | `bit-and`, `bit-or`, `bit-xor`, `bit-not`, `bit-shl`, `bit-shr` | both |
| Containers | `make-vector`, `vector`, `vector-ref`, `vector-set!`, `vector-length`, `vector?`, `make-matrix`, `matrix-ref`, `matrix-set!`, `matrix-rows`, `matrix-cols`, `matrix?`, `make-blob`, `blob-ref`, `blob-set!`, `blob-length`, `blob?`, `make-hash-table`, `hash-set!`, `hash-ref`, `hash-has?`, `hash-del!`, `hash-count`, `hash-keys`, `hash-table?` | both |
| String | `string-length`, `string-ref`, `substring`, `string-append`, `string-search`, `string-split`, `char->string`, `number->string`, `string->number`, `symbol->string`, `string->symbol` | both |
| I/O | `princ`, `newline`, `repr` | both |
| System | `set-seed!`, `rand`, `rand-int`, `clock`, `now` | both |
| Control | `try`, `raise`, `apply`, `read-string`, `read-all`, `macroexpand-1`, `provide`, `provided?` | both |
| File/System | `load`, `require`, `eval`, `read-file`, `write-file`, `append-file`, `file-exists?`, `list-dir`, `getenv`, `args`, `exit` | `FULL` only |

Common host forms:

| Form | Meaning |
|---|---|
| `(type-of x)` | Return `:pair`, `:nil`, `:number`, `:symbol`, `:string`, `:fn`, `:macro`, `:prim`, `:cfunc`, or `:ptr`. |
| `(number->string n [radix])` | Convert a number to a string. Radix defaults to 10 and must be an integer 2..16 (a bad radix raises). Radix 10 renders any number, fractions included; any other radix is digit-exact and requires an exact integer value. |
| `(try thunk)` | Run `(thunk)`. Return its value, or an error value `(:error . "message")` on failure. |
| `(raise message)` | Raise a catchable script error. `message` is stringified before it reaches the runtime error handler. |
| `(apply f arglist)` | Call `f` with the elements of `arglist`; `f` may be a closure, host primitive, or kernel primitive. |
| `(read-string s)` | Parse the first s-expression in `s` and return it as data, without evaluating it. Empty input returns `nil`; input length is not clipped to a fixed reader buffer. |
| `(macroexpand-1 form)` | Expand one symbolic macro call, or return `form` unchanged. Quote the form to inspect: `(macroexpand-1 '(when 1 2))`. |
| `(macroexpand form)` | Full expansion: loop `macroexpand-1` to a fixpoint. Core function (`core/36-recover.lsp`), not a host primitive. |
| `(bit-and a b)` / `(bit-or a b)` / `(bit-xor a b)` / `(bit-not a)` / `(bit-shl a n)` / `(bit-shr a n)` | 32-bit integer bitwise ops. Operands must be finite, integral, and in signed 32-bit range; invalid inputs raise instead of truncating. Negative operands use two's-complement bits, e.g. `(bit-and -1 255)` → `255`. `bit-shr` is a **logical** (zero-fill) right shift; shift counts are masked to `n & 31`. Results remain subject to KEC's single-precision number limit. |
| `(sin x)` / `(cos x)` / `(tan x)` / `(atan2 y x)` | Trigonometry in **radians** (`atan2` takes `(y x)` like C, resolving the full `-pi..pi` range). `pi` and `tau` are Core constants. Single-precision: results carry ~1e-7 error, so `(sin pi)` is `~1e-7`, not `0` — compare with an epsilon, never `(is …)`. |
| `(now)` vs `(clock)` | `(now)` is **monotonic** elapsed wall-clock seconds **since this interpreter context opened** (for timers, animation, elapsed-time); `(clock)` is **CPU** seconds (for profiling). `now` never goes backward, and the per-context baseline keeps single-precision numbers sub-millisecond for the life of any session. |
| `(set-seed! n)` | Reseed this interpreter's self-contained PRNG from a signed 32-bit integer and return `n`. A fixed seed makes `rand` / `rand-int` **reproducible** across runs and platforms without sharing state between contexts. `rand-int` likewise requires an integral bound, and the bound must be positive. |
| `(bound? sym)` | Truthy if `sym` has a global binding, even when its value is `nil`. Errors if the argument is not a symbol: `(bound? 'car)`. |
| `(globals [prefix])` | A fresh list of the globally-bound symbols, optionally filtered to names starting with `prefix`. Order is unspecified; treat the list as read-only (it is yours to keep, but the symbols are interned). `(globals "string-")`. |
| `(fn-params f)` | The parameter list of a closure or macro (a fresh copy), `nil` for a built-in (no Lisp parameters), or an error if `f` is not a function. For `describe-function`-style help. |
| `(read-all s)` | Parse **every** top-level form of `s` and return them as a list in source order (the multi-form companion to `read-string`). Nothing is evaluated. Empty/blank input returns `nil`. |
| `(string-search haystack needle)` | 0-based index of the first occurrence of `needle` in `haystack`, or `nil` if absent. |
| `(eval form)` | Evaluate an already-read data form in the live image and return its value. `(eval (read-string s))` reads and runs one form; `(for-each eval (read-all s))` runs a whole config string. **`FULL` only** — a privileged editor/REPL-tier capability, deliberately not in `SANDBOX`. |
| `(load path)` | Read and evaluate a file. A **relative** path resolves against the **loading file's directory** (the same dependency graph `kec build` bundles), falling back to the CWD when no file exists at the file-relative candidate; at the top level (REPL, `kec eval`) relative paths are CWD-relative. Absolute paths pass through. `FULL` only. |
| `(provide feature)` / `(provided? feature)` | Mark and query loaded features. |
| `(require key [path])` | Load a feature once. The path resolves like `load`'s. `FULL` only. |
| `(read-file path)` | Return file contents as a string. `FULL` only. |
| `(write-file path value)` / `(append-file path value)` | Write or append a stringified value. Both raise a catchable error on I/O failure. `FULL` only. |
| `(file-exists? path)` | Truthy if a path exists. `FULL` only. |
| `(list-dir path)` | Return directory entry names, excluding `.` and `..`; order is unspecified. `FULL` only. |
| `(getenv name)` | Return an environment value or `nil`. `FULL` only. |

Path and name arguments to the file/system primitives are bounded (4 KB): an
over-long path raises a catchable "path too long" error instead of being
silently truncated — a clipped path would name a *different* file. The same
guard applies to `string->number` / `string->symbol` / `symbol->string`
arguments and to `provide` / `provided?` / `require` feature names (1 KB).

### Containers

Vectors, matrices, blobs, and hash tables are **foreign (`:ptr`) objects** with
O(1) access — the optimized alternative to cons-list and alist traversal for
grids, binary assets, rings, and keyed tables. Because they are foreign objects,
`=` / `is` compare them **by identity**, not contents: use helpers such as
`vector->list` / `hash->alist` + `equal?` when you need content comparison. Core
(`core/52-container.lsp`) layers iterative Lisp conveniences over the primitives:
`vector->list`, `list->vector`, `vector-fill!`, `vector-copy`, `vector-map`,
`vector-for-each`, `matrix-fill!`, `matrix-map`, `matrix-for-each`,
`hash->alist`, `alist->hash`, `hash-values`, and `hash-for-each`.

| Form | Meaning |
|---|---|
| `(make-vector n [init])` | A fixed-length vector of integer length `n`, each element `init` (default `nil`). Fractional or unsafe lengths raise. |
| `(vector a b ...)` | A vector of the given elements. |
| `(vector-ref v i)` / `(vector-set! v i x)` | 0-based integer indexed read / write; both raise on a fractional or out-of-range index. `vector-set!` returns `x`. |
| `(vector-length v)` / `(vector? x)` | Element count / type test. |
| `(make-matrix rows cols [init])` | A flat row-major 2D array of integer dimensions, each cell `init` (default `nil`). Negative, fractional, non-finite, or oversized dimensions raise. |
| `(matrix-ref m row col)` / `(matrix-set! m row col x)` | 0-based integer indexed read / write; row-major O(1). Both raise on fractional or out-of-range indices. `matrix-set!` returns `x`. |
| `(matrix-rows m)` / `(matrix-cols m)` / `(matrix? x)` | Dimension accessors / type test. |
| `(matrix-fill! m x)` / `(matrix-map f m)` / `(matrix-for-each f m)` | Iterative row-major helpers. `matrix-fill!` mutates and returns `m`; `matrix-map` returns a fresh matrix with the same dimensions; `matrix-for-each` returns `nil`. |
| `(make-blob length [init-byte])` | A binary-safe byte buffer of integer length, filled with `init-byte` (default `0`). The byte must be an exact integer in `0..255`. |
| `(blob-ref b i)` / `(blob-set! b i byte)` | 0-based byte read / write. Indices must be exact integers; bytes must be exact integers in `0..255`. `blob-set!` returns the byte. |
| `(blob-length b)` / `(blob? x)` | Byte length / type test. |
| `(make-hash-table)` | An empty hash table. Keys may be **numbers** (by value), **symbols** (by identity), or **strings** (by content); any other key type raises. |
| `(hash-set! h k v)` / `(hash-ref h k [default])` | Associate `k`→`v` (returns `v`) / look `k` up, returning `default` (or `nil`) when absent. |
| `(hash-has? h k)` / `(hash-del! h k)` | Membership test / delete (returns `t` if present, else `nil`). |
| `(hash-count h)` / `(hash-keys h)` / `(hash-table? x)` | Live entry count / fresh list of keys (unspecified order) / type test. |

## Errors

Runtime errors route through `fe_error`. The KEC runtime installs a recovery
handler so errors unwind to the nearest guard: a REPL prompt, script boundary,
or `(try ...)`.

```lisp
(let r (try (fn () (raise "bad input"))))
(if (error? r)
    (error-message r)
    r)
```

`try` returns the thunk value on success. On failure, it returns the same
`(:error . "message")` shape produced by Core's `error` helper.

## Protected Standard Bindings

After the runtime loads the kernel primitives, host primitives, and Core prelude,
standard globals are protected from rebinding. Attempts to `(set map ...)`,
`(set cons ...)`, `(set %append ...)`, or evaluate a top-level `(let map ...)`
raise a catchable error and leave the original binding intact. Local lexical
bindings are still allowed; the guard protects the global method table that
macros and the prelude depend on. Mutable runtime registries such as `%plists`
remain writable by their owning Core/runtime functions.

## Limits And Portability

| Limit | Practical effect |
|---|---|
| Single-precision numbers | Treat numbers as floats; exact integer work is limited to +/-2^24. |
| Bounded GC root stack | Prefer `while`, `dotimes`, `dolist`, or `fold-left` for deep traversals. |
| No tail-call optimization | Deep recursive code can overflow. Core list functions are iterative for this reason. |
| Containers compare by identity | Vectors, matrices, blobs, and hashes are `:ptr` objects; `=`/`is` test identity. Use conversion helpers where a structural comparison is needed. String hash keys hash and compare by their **full content**, at any length — the same content equality `is` applies to strings. |
| `eval` is `FULL`-tier | `SANDBOX` contexts have no `eval`; use macros for code generation and `read-string`/`read-all` to parse data. |
| Referencing an unbound symbol silently yields `nil` | There is no "unbound variable" error on read — a typo'd name reads as `nil` instead of failing loudly. Use `(bound? 'name)` to check whether a symbol has ever been bound; calling one (as the operator of a list) still errors, since `nil` is not callable. |
| Strings are null-terminated | Strings are not binary-safe; use blobs for embedded NULs and binary asset bytes. |
| Standard globals are protected | Rebinding load-bearing kernel/host/Core names raises a catchable error. Define new names for overrides or use local lexical bindings. |
| Integer-only host APIs validate | Vector/matrix/blob sizes and indices, blob bytes, bitwise operands, RNG seeds, `rand-int` bounds, string indices (`string-ref`, `substring`), char codes (`char->string`, `string-split` separators — bytes `0..255`), `number->string` radixes, and `exit` codes reject fractional, non-finite, or unsafe values with a catchable error instead of silently narrowing them. `rand-int` additionally requires a **positive** bound (`[0, n)` is empty otherwise). |

For implementation details, see [Fe Kernel - Internals](/kec-lisp/fe-kernel/)
and [Memory Model](/kec-lisp/memory-model/).

## Quick Lookup

| Category | Names |
|---|---|
| Kernel binding/forms | `let`, `set`, `fn`, `mac`, `quote`, `if`, `and`, `or`, `while`, `do` |
| Kernel data | `cons`, `car`, `cdr`, `setcar`, `setcdr`, `list`, `atom`, `not`, `is` |
| Kernel numbers/I/O | `<`, `<=`, `+`, `-`, `*`, `/`, `print` |
| Definitions | `define`, `defn`, `defmacro`, `defvar` |
| Control | `cond`, `case`, `when`, `unless`, `begin`, `prog1`, `let*`, `letrec`, `dotimes`, `dolist` |
| Lists/alists | `nth`, `length`, `reverse`, `append`, `last`, `member`, `assoc`, `take`, `drop`, `range`, `get`, `put`, `has?`, `keys`, `values`, `merge` |
| Comparison/predicates | `=`, `==`, `/=`, `equal?`, `>`, `>=`, `zero?`, `positive?`, `negative?`, `nil?`, `pair?`, `even?`, `odd?`, `number?`, `symbol?`, `string?`, `fn?` |
| Higher-order | `map`, `filter`, `remove`, `fold-left`, `fold-right`, `for-each`, `find`, `any?`, `every?`, `count` |
| Containers | `make-vector`, `vector`, `vector-ref`, `vector-set!`, `vector-length`, `vector?`, `vector->list`, `list->vector`, `vector-map`, `vector-for-each`, `vector-fill!`, `vector-copy`, `make-matrix`, `matrix-ref`, `matrix-set!`, `matrix-rows`, `matrix-cols`, `matrix?`, `matrix-fill!`, `matrix-map`, `matrix-for-each`, `make-blob`, `blob-ref`, `blob-set!`, `blob-length`, `blob?`, `make-hash-table`, `hash-set!`, `hash-ref`, `hash-has?`, `hash-del!`, `hash-count`, `hash-keys`, `hash-table?`, `hash-values`, `hash->alist`, `alist->hash`, `hash-for-each` |
| Strings | `str`, `join`, `split`, `format`, `string-length`, `string-ref`, `substring`, `string-append`, `string-search`, `string-split`, `char->string`, `number->string`, `string->number`, `symbol->string`, `string->symbol` |
| String toolkit | `char-upcase`, `char-downcase`, `string-upcase`, `string-downcase`, `pad-left`, `pad-right`, `string-repeat`, `string-prefix?`, `string-suffix?`, `string-contains?` |
| Bitwise | `bit-and`, `bit-or`, `bit-xor`, `bit-not`, `bit-shl`, `bit-shr` |
| RNG | `set-seed!`, `rand`, `rand-int` |
| Errors/recovery/loading | `try`, `raise`, `unwind-protect`, `ignore-errors`, `condition-case`, `macroexpand-1`, `macroexpand`, `error`, `error?`, `error-message`, `provide`, `provided?`, `require`, `load` |
| Full-profile file/system | `read-file`, `write-file`, `append-file`, `file-exists?`, `list-dir`, `getenv`, `args`, `exit` |
