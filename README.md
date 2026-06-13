# KEC Lisp

**KEC Lisp (KN-86 Standard)** is the domain-specific authoring language of the
Kinoshita Electronics Consortium KN-86 Deckline — a small, embeddable Lisp with
a frozen kernel, a real standard library, and a capability-gated FFI. This
repository is the **standalone, portable language**: a kernel, the KEC Core
prelude, a host runtime, a `kec` command-line tool, and a test harness. You can
install it, write scripts, compile them, and run them on any machine with a C
compiler — no KN-86 hardware required.

The device firmware (nOSh) **vendors this repository** and extends it with the
KN-86 device primitives (display, audio, missions, CIPHER) through the
documented FFI bridge. Everything that needs the hardware lives downstream;
everything that runs on a laptop lives here.

> Ratified by **ADR-0037** and the canonical
> [KEC Lisp Language Standard](https://kn86-deckline.com). This implementation
> conforms to the standard — the standard is prescriptive, not descriptive.

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

---

## The four layers

KEC Lisp is composed of four named layers (standard §2). This repo ships the
first two and a portable slice of the third; the device tier is downstream.

| Layer | What it is | In this repo? |
|---|---|---|
| **Fe Kernel** | The frozen `rxi/fe` 1.0 VM — 26 primitives, reader, evaluator, arena/GC. The "machine." | ✅ `kernel/` (vendored, never forked) |
| **KEC Core** | The prelude: `map filter fold cond when defn let* …` — pure KEC Lisp that turns the kernel into a usable language. | ✅ `core/` (the heart of this repo) |
| **KEC Stdlib** | The FFI surface — C exposed to KEC Lisp, tiered by capability. | ✅ *portable slice* (`host/`): `type-of`, math, strings, I/O, sys. ❌ *device slice* (NoshAPI: display/audio/missions) — downstream. |
| **Cart Grammar** | The authoring DSL (`defcell`/`defmission`) on top. | ❌ downstream (built after Core freezes) |

- **"KEC Lisp the language"** = Fe Kernel + KEC Core.
- **"KEC Lisp the platform"** = + KEC Stdlib.

See [`docs/boundary.md`](docs/boundary.md) for exactly what ships here vs. what
the firmware adds, and why the line sits where it does.

---

## Build

Requires CMake ≥ 3.16 and a C11 compiler.

```sh
cmake -S . -B build
cmake --build build
```

This produces a single self-contained binary, `build/kec`, with KEC Core baked
in (no runtime file lookup).

## Use

```sh
kec                      # start the REPL
kec run FILE [args...]   # evaluate a script (args reach (args))
kec eval "EXPR"          # evaluate one expression and print it
kec build FILE [-o OUT]  # inline (load ...)s, parse-check, write a .kec bundle
kec test [FILE...]       # run the test harness over FILE(s)
kec version | help
```

```sh
$ kec run examples/fib.lsp
fib 0..14: 0 1 1 2 3 5 8 13 21 34 55 89 144 233 377

$ kec eval '(map (fn (x) (* x x)) (range 1 6))'
(1 4 9 16 25)
```

### "Compile"

The Fe Kernel is a tree-walking interpreter — there is no separate bytecode
stage. `kec build` is an honest ahead-of-time step: it **inlines** every
`(load "...")`, **parse-checks** the whole program, and writes a single
self-contained `.kec` bundle that `kec run` executes directly. Link + validate
+ package, not a fictional bytecode.

## Test

```sh
cd build && ctest --output-on-failure
```

Tests are written in KEC Lisp using the harness in
[`tests/harness.lsp`](tests/harness.lsp) — `(deftest …)`, `(check …)`,
`(check-err …)`. Each file runs under `kec test`, whose exit code is the number
of failed checks, so the suite gates CI. The conformance suite is the
executable encoding of standard §4.

---

## A 60-second tour of the language

```lisp
; numbers are single-precision floats; nil is false and the empty list
(+ 1 2)                  ; => 3
(if nil 'yes 'no)        ; => no

; bind with define / defn / let.  set mutates.  = / == compare.
(define xs (range 0 5))  ; => (0 1 2 3 4)
(defn sq (x) (* x x))
(= 3 3)                  ; => t   (value equality)

; higher-order + control
(map sq xs)                       ; => (0 1 4 9 16)
(filter odd? xs)                  ; => (1 3)
(fold-left + 0 xs)                ; => 10
(cond ((> 1 2) 'a) (else 'b))     ; => b
(let* ((a 2) (b (* a 3))) (+ a b)) ; => 8

; strings
(str "n=" 42)                     ; => "n=42"
(format "%s is %d" "x" 7)         ; => "x is 7"
(join (map number->string xs) ",") ; => "0,1,2,3,4"
```

Full reference: [`docs/language.md`](docs/language.md).

### Good to know

- **`=` / `==` compare, `set` assigns, `let` / `define` / `defn` bind.** KEC
  renames Fe's assignment verb to `set` so `=` means value equality (standard
  §4.1). `let` binds locals *and* works at the top level.
- **Numbers are single-precision floats.** Integers are exact only within ±2²⁴.
- **`is` is identity on pairs** — compare lists element-wise, not with `=`/`is`.
- **Deep recursion** runs into the thousands on desktop; KEC Core stays
  iterative so a library call never hits the ceiling.

---

## Repository layout

```
kernel/    Fe VM (vendored rxi/fe 1.0, frozen)        — Layer 0
core/      KEC Core prelude, 00-def … 60-str          — Layer 1 (KEC Lisp)
host/      portable host stdlib (type-of/math/str/io) — Layer 2 (C)
runtime/   embedding API, error recovery, Core load   — Layer 2 (C)
cli/       the `kec` driver                            — repl/run/build/test
tools/     mkembed — bakes Core into the binary
tests/     harness.lsp + conformance suite
examples/  runnable scripts
docs/      language reference · ffi bridge · boundary
```

## Embedding KEC Lisp / adding your own primitives

The whole point of the layering is that a downstream host (the KN-86 firmware,
or your own program) links `kec_core` and registers its own C primitives
through the same `bind` seam Core's stdlib uses:

```c
#include "kec.h"
kec_State *S = kec_open(16u*1024*1024, KEC_PROFILE_FULL);
kec_bind_fe(kec_fe(S), "beep", my_beep_cfunc);   /* now callable as (beep …) */
kec_eval_string(S, "(beep 440)", NULL);
kec_close(S);
```

The FFI bridge contract — registration, C↔Lisp marshalling, opaque handles,
capability tiers, error propagation — is [`docs/ffi-bridge.md`](docs/ffi-bridge.md).

## License

MIT. The Fe Kernel is © 2020 rxi (MIT), vendored from `rxi/fe` with small
documented KEC changes (assignment verb `=`→`set`, top-level `let` binds
globally, configurable GC-stack size). Everything else is © Kinoshita
Electronics Consortium (MIT). See [`LICENSE`](LICENSE).
