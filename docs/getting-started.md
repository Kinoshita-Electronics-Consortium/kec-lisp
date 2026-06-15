---
title: Getting Started
description: Build the kec binary, run the REPL, and write your first KEC Lisp program.
---

KEC Lisp builds to a single command-line tool, `kec`, that runs on a normal
computer — no KN-86 hardware required.

## Get the source

Clone the repository from GitHub:

```sh
git clone https://github.com/Kinoshita-Electronics-Consortium/kec-lisp.git
cd kec-lisp
```

## Build

You need CMake and a C compiler.

```sh
cmake -S . -B build       # configure (Release by default)
cmake --build build       # build → build/kec
```

That produces `build/kec`. Run the test suite to confirm everything works:

```sh
ctest --test-dir build --output-on-failure
```

## The `kec` CLI

```sh
kec                      # REPL
kec run FILE [args...]   # run a script; args reach Lisp via (args)
kec eval "EXPR"          # evaluate one expression, print the result
kec build FILE [-o OUT]  # inline (load ...)s, parse-check, write one .kec
kec test [FILE...]       # run the harness over FILE(s), or the whole suite
```

A quick taste:

```sh
$ kec eval '(map (fn (x) (* x x)) (range 1 6))'
(1 4 9 16 25)
```

> **`kec build` is not a compiler.** Fe is a tree-walking interpreter — `kec
> build` inlines any `(load ...)`s, checks that the whole program parses, and
> writes a single self-contained `.kec` file you can `kec run`.

## Your first program

Put this in `hello.lsp`:

```lisp
(defn fizzbuzz (n)
  (dotimes (i n)
    (let k (+ i 1))
    (princ (cond ((is (mod k 15) 0) "FizzBuzz")
                 ((is (mod k 3)  0) "Fizz")
                 ((is (mod k 5)  0) "Buzz")
                 (else (number->string k))))
    (newline)))
(fizzbuzz 15)
```

…and run it:

```sh
kec run hello.lsp
```

## A few things worth knowing

- Bind with `define`, `defn`, or `let`. **Mutate with `set`.** Compare with `=`
  (or its alias `==`).
- `nil` is the only false value, and also the empty list. There are no other
  booleans — `0` and `""` are both true.
- Numbers are single-precision floats; integers are exact only within ±2²⁴.
- Use `equal?` for element-by-element list comparison; `is` / `=` on two pairs
  check **identity**, not contents.

The full story is in the [Language Reference](/kec-lisp/language/).

## Hacking on the standard library

Core (`core/*.lsp`) is baked into the `kec` binary at build time, so a Core edit
normally needs a rebuild. While iterating, point the CLI at the source files
instead:

```sh
KEC_CORE_DIR=$PWD/core ./build/kec eval '(your-core-fn ...)'
```

The CLI re-loads those `.lsp` files (in `NN-` name order) over the embedded Core
at startup, so adding or changing definitions takes effect with no rebuild. It
*layers over* the baked-in copy — a definition you **delete** lingers until you
rebuild. Dev convenience only; the embedded Core is what ships and what the
firmware vendors.
