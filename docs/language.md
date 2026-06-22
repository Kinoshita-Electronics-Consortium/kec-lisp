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

KEC Lisp uses **19 distinct punctuation characters**. Ten are recognized by the
reader (`read_` in `kernel/fe.c`) as structure; nine appear inside the names of
kernel primitives and Core definitions you have to type. `!`, `#`, `&`, `%`,
`^`, `$`, `~`, and `|` are *not* used — there is no bang-mutation convention and
none are reader-special.

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
| `(equal? a b)` | Recursive pair/list comparison. |

## Evaluation

Evaluation follows the usual Lisp shape:

1. A literal number, string, or `nil` evaluates to itself.
2. A symbol evaluates to its current binding.
3. A list evaluates its operator, then applies it according to what the operator
   is.
4. Function and C primitive arguments are evaluated left to right before the
   call.
5. Macros receive their arguments unevaluated; the macro result replaces the
   call and is evaluated again.
6. Special forms such as `if`, `let`, `set`, `fn`, `mac`, `quote`, `and`, `or`,
   `while`, and `do` control their own evaluation rules.

There is no Lisp-level `eval`. `(read-string s)` parses one s-expression and
returns it as data; it does not run it.

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
numeric filename order.

### Definitions

| Form | Expands to |
|---|---|
| `(defn name (params...) body...)` | `(set name (fn (params...) body...))` |
| `(defmacro name (params...) body...)` | `(set name (mac (params...) body...))` |
| `(define name value)` | `(set name value)` |
| `(define (f args...) body...)` | `(set f (fn (args...) body...))` |
| `(defvar name value)` | `(if (bound? 'name) name (do (set name value) name))` |

Each definition form returns the value it defines, which makes REPL output and
definition chaining more useful than bare `set`. `defvar` only assigns when
`name` is currently **unbound**, so a user/config value set earlier survives a
later library load.

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
| `equal?` | Recursive list equality. |
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

- **Never shadow** the frozen kernel primitives (`cons`, `car`, `cdr`, `list`,
  `is`, `not`, `atom`, `if`, `let`, `set`, `fn`, `mac`, `do`, `while`, `and`,
  `or`, `quote`, `<`, `<=`, `+`, `-`, `*`, `/`) or `gensym`. The macro expanders
  emit these by name; redefining them corrupts every macro.
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
| `(pad-left s width [pad])` / `(pad-right s width [pad])` | Pad `s` to `width` with `pad` (default `" "`). Never truncates: an `s` already ≥ `width` is returned unchanged. |
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
| Math | `mod`, `floor`, `ceil`, `round`, `abs`, `sqrt`, `pow` | both |
| Bitwise | `bit-and`, `bit-or`, `bit-xor`, `bit-not`, `bit-shl`, `bit-shr` | both |
| Containers | `make-vector`, `vector`, `vector-ref`, `vector-set!`, `vector-length`, `vector?`, `make-hash-table`, `hash-set!`, `hash-ref`, `hash-has?`, `hash-del!`, `hash-count`, `hash-keys`, `hash-table?` | both |
| String | `string-length`, `string-ref`, `substring`, `string-append`, `string-search`, `char->string`, `number->string`, `string->number`, `symbol->string`, `string->symbol` | both |
| I/O | `princ`, `newline`, `repr` | both |
| System | `set-seed!`, `rand`, `rand-int`, `clock` | both |
| Control | `try`, `raise`, `apply`, `read-string`, `read-all`, `macroexpand-1`, `provide`, `provided?` | both |
| File/System | `load`, `require`, `eval`, `read-file`, `write-file`, `append-file`, `file-exists?`, `list-dir`, `getenv`, `args`, `exit` | `FULL` only |

Common host forms:

| Form | Meaning |
|---|---|
| `(type-of x)` | Return `:pair`, `:nil`, `:number`, `:symbol`, `:string`, `:fn`, `:macro`, `:prim`, `:cfunc`, or `:ptr`. |
| `(number->string n [radix])` | Convert a number to a string. Radix defaults to 10; 2, 8, and 16 are supported. |
| `(try thunk)` | Run `(thunk)`. Return its value, or an error value `(:error . "message")` on failure. |
| `(raise message)` | Raise a catchable script error. `message` is stringified before it reaches the runtime error handler. |
| `(apply f arglist)` | Call `f` with the elements of `arglist`; `f` may be a closure, host primitive, or kernel primitive. |
| `(read-string s)` | Parse the first s-expression in `s` and return it as data, without evaluating it. Empty input returns `nil`. |
| `(macroexpand-1 form)` | Expand one symbolic macro call, or return `form` unchanged. Quote the form to inspect: `(macroexpand-1 '(when 1 2))`. |
| `(macroexpand form)` | Full expansion: loop `macroexpand-1` to a fixpoint. Core macro (`core/36-recover`), not a host primitive. |
| `(bit-and a b)` / `(bit-or a b)` / `(bit-xor a b)` / `(bit-not a)` / `(bit-shl a n)` / `(bit-shr a n)` | 32-bit integer bitwise ops. Operands are taken mod 2³² (a negative number uses its two's-complement bits, e.g. `(bit-and -1 255)` → `255`). `bit-shr` is a **logical** (zero-fill) right shift; shift counts are masked to `n & 31`. Exact only within ±2²⁴ like any KEC number. |
| `(set-seed! n)` | Reseed the self-contained PRNG from `n` and return `n`. A fixed seed makes `rand` / `rand-int` **reproducible** across runs and platforms (deck-state-seeded generation). |
| `(bound? sym)` | Truthy if `sym` has a non-nil global binding. `nil` is absence here, so a symbol bound to `nil` reads as unbound. Errors if the argument is not a symbol: `(bound? 'car)`. |
| `(globals [prefix])` | A fresh list of the globally-bound symbols, optionally filtered to names starting with `prefix`. Order is unspecified; treat the list as read-only (it is yours to keep, but the symbols are interned). `(globals "string-")`. |
| `(fn-params f)` | The parameter list of a closure or macro (a fresh copy), `nil` for a built-in (no Lisp parameters), or an error if `f` is not a function. For `describe-function`-style help. |
| `(read-all s)` | Parse **every** top-level form of `s` and return them as a list in source order (the multi-form companion to `read-string`). Nothing is evaluated. Empty/blank input returns `nil`. |
| `(string-search haystack needle)` | 0-based index of the first occurrence of `needle` in `haystack`, or `nil` if absent. |
| `(eval form)` | Evaluate an already-read data form in the live image and return its value. `(eval (read-string s))` reads and runs one form; `(for-each eval (read-all s))` runs a whole config string. **`FULL` only** — a privileged editor/REPL-tier capability, deliberately not in `SANDBOX`. |
| `(load path)` | Read and evaluate a file. `FULL` only. |
| `(provide feature)` / `(provided? feature)` | Mark and query loaded features. |
| `(require key [path])` | Load a feature once. `FULL` only. |
| `(read-file path)` | Return file contents as a string. `FULL` only. |
| `(write-file path value)` / `(append-file path value)` | Write or append a stringified value. Both raise a catchable error on I/O failure. `FULL` only. |
| `(file-exists? path)` | Truthy if a path exists. `FULL` only. |
| `(list-dir path)` | Return directory entry names, excluding `.` and `..`; order is unspecified. `FULL` only. |
| `(getenv name)` | Return an environment value or `nil`. `FULL` only. |

### Containers

Vectors and hash tables (ADR-0003) are **foreign (`:ptr`) objects** with O(1)
access — the optimized alternative to cons-list and alist traversal for grids,
rings, and keyed tables. Because they are foreign objects, `=` / `is` compare
them **by identity**, not contents: use `vector->list` / `hash->alist` + `equal?`
to compare contents. Core (`core/52-container.lsp`) layers the Lisp conveniences
`vector->list`, `list->vector`, `vector-fill!`, `vector-copy`, `vector-map`,
`vector-for-each`, `hash->alist`, `alist->hash`, `hash-values`, `hash-for-each`
over the primitives.

| Form | Meaning |
|---|---|
| `(make-vector n [init])` | A fixed-length vector of `n` elements, each `init` (default `nil`). |
| `(vector a b ...)` | A vector of the given elements. |
| `(vector-ref v i)` / `(vector-set! v i x)` | 0-based indexed read / write; both raise on an out-of-range index. `vector-set!` returns `x`. |
| `(vector-length v)` / `(vector? x)` | Element count / type test. |
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

## Limits And Portability

| Limit | Practical effect |
|---|---|
| Single-precision numbers | Treat numbers as floats; exact integer work is limited to +/-2^24. |
| Bounded GC root stack | Prefer `while`, `dotimes`, `dolist`, or `fold-left` for deep traversals. |
| No tail-call optimization | Deep recursive code can overflow. Core list functions are iterative for this reason. |
| Vectors/hash compare by identity | They are `:ptr` objects; `=`/`is` test identity. Use `vector->list`/`hash->alist` + `equal?` for content. String hash keys compare over their first 1024 bytes. |
| `eval` is `FULL`-tier | `SANDBOX` contexts have no `eval`; use macros for code generation and `read-string`/`read-all` to parse data. |
| Strings are null-terminated | Strings are not binary-safe. |

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
| Containers | `make-vector`, `vector`, `vector-ref`, `vector-set!`, `vector-length`, `vector?`, `vector->list`, `list->vector`, `vector-map`, `vector-for-each`, `vector-fill!`, `vector-copy`, `make-hash-table`, `hash-set!`, `hash-ref`, `hash-has?`, `hash-del!`, `hash-count`, `hash-keys`, `hash-table?`, `hash-values`, `hash->alist`, `alist->hash`, `hash-for-each` |
| Strings | `str`, `join`, `split`, `format`, `string-length`, `string-ref`, `substring`, `string-append`, `string-search`, `char->string`, `number->string`, `string->number`, `symbol->string`, `string->symbol` |
| String toolkit | `char-upcase`, `char-downcase`, `string-upcase`, `string-downcase`, `pad-left`, `pad-right`, `string-repeat`, `string-prefix?`, `string-suffix?`, `string-contains?` |
| Bitwise | `bit-and`, `bit-or`, `bit-xor`, `bit-not`, `bit-shl`, `bit-shr` |
| RNG | `set-seed!`, `rand`, `rand-int` |
| Errors/recovery/loading | `try`, `raise`, `unwind-protect`, `ignore-errors`, `condition-case`, `macroexpand-1`, `macroexpand`, `error`, `error?`, `error-message`, `provide`, `provided?`, `require`, `load` |
| Full-profile file/system | `read-file`, `write-file`, `append-file`, `file-exists?`, `list-dir`, `getenv`, `args`, `exit` |
