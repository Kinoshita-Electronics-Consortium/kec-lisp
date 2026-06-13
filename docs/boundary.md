# Where the boundary sits

This repository is **KEC Lisp the language plus a portable host runtime**. It
deliberately stops at the KN-86 device line. This document records exactly what
ships here, what the firmware adds downstream, and the one test that decides
which side a primitive falls on.

## The test

> **Can it run on a developer's laptop with no KN-86 hardware?**
> If yes, it ships here. If it needs the framebuffer, PSG, OLED, deck-state,
> mission board, or CIPHER, it is downstream FFI.

The standard draws the same line in its own terms (§2):
*"KEC Lisp the language" = Fe Kernel + KEC Core*, and *"KEC Lisp the platform" =
+ KEC Stdlib*. This repo ships the language and a **portable slice** of the
Stdlib — enough to actually write and run scripts. The **device slice** of the
Stdlib (NoshAPI) is registered downstream through `docs/ffi-bridge.md`.

## In this repository

| Component | Layer | Why it's here |
|---|---|---|
| Fe Kernel (`kernel/`) | 0 | The VM. Vendored from `rxi/fe` with small documented KEC changes (assignment verb, top-level `let`, configurable GC stack — see CHANGELOG). |
| KEC Core (`core/`) | 1 | The prelude. Pure KEC Lisp. The heart of the language. |
| Portable host stdlib (`host/`) | 2 | `type-of`, math, strings, I/O, sys, `try`. Laptop-portable, zero device coupling. Makes scripts *runnable*. |
| Embedding API + recovery (`runtime/`) | 2 | `kec_open`, Core injection, error guard, `load`. |
| The `bind` seam + profiles | 2 | `kec_bind_fe` + `kec_Profile` — the §6 contract, exercised. |
| `kec` CLI, test harness | — | repl / run / build / test, and the conformance suite. |

`type-of` deserves a special note: KEC Core's `number?`/`string?`/`symbol?`/
`fn?` predicates require it (standard §4.7, ADR-0037 follow-on #2), and it is
perfectly portable — so it ships here, and Core is **fully conformant** out of
the box, starred predicates included.

## Downstream (the firmware vendors this repo and adds)

| Component | Layer | Where it lives |
|---|---|---|
| NoshAPI device primitives — `text-*`, `gfx-*`, `psg-*`, `spawn-cell`, `mission-*`, `cipher-*`, `cell-*`, `render/*` | 2 (device tier) | nOSh firmware, bound via `kec_bind_fe` |
| Capability tiers — all-cart / mission-context / REPL-read-only / system-render | 2 | firmware, as per-context binding-sets |
| Cart Grammar — `defcell`, `defmission`, `defstruct`, `defdomain` | 3 | firmware authoring layer, after Core freezes |

None of these can run standalone — they need the hardware or the runtime's
integrity cores. They compose onto KEC Lisp through exactly one seam
(`kec_bind_fe`) and one rule (capability = binding-set), both documented and
demonstrated here.

## How the firmware consumes this repo

1. **Vendor** `kernel/`, `core/`, `host/`, `runtime/` into the nOSh build (the
   same way nOSh already vendors `rxi/fe`).
2. **Open** a context with `kec_open(...)` (or a custom arena size for the
   256 KB device budget), which loads KEC Core.
3. **Bind** the device tier with `kec_bind_fe` per context, choosing the
   binding-set that is each context's sandbox (cart vs. system vs. REPL).
4. **Author** carts and system surfaces against KEC Core + that tier — the same
   vocabulary this repo documents, plus the device primitives.

Kernel changes are minimal and documented; Core is versioned as a unit
(standard §8); the device tier evolves independently behind the FFI bridge.
