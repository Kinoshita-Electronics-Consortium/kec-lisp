<p align="center">
  <img src="assets/kec-lisp-logo.png" alt="KEC Lisp" width="320">
</p>

# KEC Lisp

A small Lisp. It's the scripting language for the KN-86, a handheld terminal
project. This repo is the language on its own — the interpreter, a standard
library, a `kec` command-line tool, and tests — so you can write KEC Lisp and
run it without any of the KN-86 hardware.

The KN-86 firmware uses this as a library and adds its own primitives (graphics,
sound, and so on) on top. None of that device stuff is here — this is just the
language.

**Documentation:** <https://kinoshita-electronics-consortium.github.io/kec-lisp/>

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

## Build

Needs CMake and a C compiler.

```sh
cmake -S . -B build
cmake --build build
```

That gives you `build/kec`.

## Use

```sh
kec                      # REPL
kec run FILE [args...]   # run a script
kec eval "EXPR"          # evaluate one expression
kec build FILE [-o OUT]  # bundle a script (and its loads) into one .kec file
kec test [FILE...]       # run tests (no FILE = the whole embedded suite)
```

```sh
$ kec eval '(map (fn (x) (* x x)) (range 1 6))'
(1 4 9 16 25)
```

Note: `kec build` isn't a compiler — Fe is a tree-walking interpreter. It
inlines top-level literal `(load "...")` forms, checks the whole thing parses,
and writes a single self-contained `.kec` file you can `kec run`.

## The language

It's [Fe](https://github.com/rxi/fe) (rxi's tiny Lisp) plus a standard library
written in Lisp (`core/`) and a handful of C primitives (`host/`). If you've
used a Lisp before it'll feel familiar. A few things worth knowing:

- Bind with `define`, `defn`, or `let`. Mutate with `set`. Compare with `=`.
- `nil` is false and the empty list. There are no other booleans.
- Numbers are single-precision floats.
- Use `equal?` for element-by-element list comparison; `=` on two lists checks
  identity, not contents.

Fuller notes are in [docs/language.md](docs/language.md).

## Layout

```
kernel/   the Fe interpreter (vendored from rxi/fe, lightly modified)
core/     the standard library, written in KEC Lisp
host/     C primitives — type-of, math, strings, I/O
runtime/  the embedding API
cli/      the kec command
tests/    a test harness (written in KEC Lisp) and the test suite
examples/ runnable scripts
```

## Hacking on Core

Core (`core/*.lsp`) is baked into the `kec` binary at build time, so normally a
Core edit needs a rebuild. While iterating, point the CLI at the source files
instead:

```sh
KEC_CORE_DIR=$PWD/core ./build/kec eval '(your-core-fn ...)'
```

The CLI re-loads those `.lsp` files (in `NN-` name order) over the embedded Core
at startup — adding or changing definitions takes effect with no rebuild. It
layers over the baked-in copy, so a definition you *delete* lingers until you
rebuild. Dev convenience only; the embedded Core is what ships.

## Embedding

You can embed KEC Lisp in a C program: open an interpreter, register your own C
functions, and they're callable from Lisp.

```c
#include "kec.h"
kec_State *S = kec_open(16u * 1024 * 1024, KEC_PROFILE_FULL);
kec_bind_fe(kec_fe(S), "beep", my_beep);     // now (beep 440) works
kec_eval_string(S, "(beep 440)", NULL);
kec_close(S);
```

If you'd rather not use the heap (e.g. on the KN-86 device), give it your own
buffer with `kec_open_with_arena(buf, size, profile)` — same as `kec_open` but
no malloc of the arena, and the buffer is never freed by `kec_close`.

This is how the KN-86 firmware adds its device primitives. Details in
[docs/ffi-bridge.md](docs/ffi-bridge.md).

## License

MIT. The interpreter in `kernel/` is from [rxi/fe](https://github.com/rxi/fe)
(also MIT), with a few small changes noted in the [CHANGELOG](CHANGELOG.md).
