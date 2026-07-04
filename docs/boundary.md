---
title: What's Here
description: What the standalone KEC Lisp repo includes, and what lives in the KN-86 firmware instead.
---

This repo is the KEC Lisp language and a runtime you can use on a normal
computer. The KN-86-specific stuff isn't here — it lives in the firmware, which
uses this repo as a library.

Rough rule for what's in: if it runs on a laptop with no KN-86 hardware, it's
here. If it needs the screen, the sound chip, save storage, or the game runtime,
it's in the firmware.

## In this repo

| Part | What it is |
|---|---|
| `kernel/` | the Fe interpreter (vendored from rxi/fe, with a few small changes — see CHANGELOG) |
| `core/` | the standard library, written in KEC Lisp |
| `host/` | C primitives — type-of, math, strings, I/O, a couple of system calls |
| `runtime/` | the embedding API (open a context, load Core, eval, bind C functions) |
| `cli/` | the `kec` command |
| `tests/` | the test harness and suite |

A **host-agnostic editor/REPL extended-library tier** (`editor/*.lsp`) —  the
text buffer, undo, cursor/view, keymap-as-data + dispatch, the token ranker, the
REPL loop, and serialize/load that host **knEmacs** and a strong standalone REPL
— sits above Core (`provide`-gated, opt-in). It passes the same "runs on a
laptop with no KN-86" test, so it lives here; only device concerns (CIPHER-LINE,
the physical key matrix, deck state, missions, persistence backing) stay in the
firmware, bound through an abstract host seam. See
[ADR-0002](adr/ADR-0002-editor-repl-extended-library-tier.md) for the design and
the [Extended Library Reference](extended-library.md) for the full API.

`type-of` is here even though it's a C primitive, because Core's
`number?`/`string?`/`symbol?`/`fn?` use it — it's small and portable, so Core
works out of the box.

## In the firmware (not here)

The KN-86 firmware vendors this repo and adds its own C primitives on top:

- the device API — drawing, audio, save state, missions, the CIPHER voice
- per-context permission tiers (which primitives a cart vs. a system screen can
  call)
- the cartridge authoring macros (`defcell`, `defmission`, …)

None of these run without the hardware and the firmware's runtime, so they
aren't part of the standalone language.

## How the firmware uses it

1. Vendor `kernel/`, `core/`, `host/`, `runtime/` into the firmware build.
2. Open a context with `kec_open(...)`, which loads Core.
3. Register the device primitives with `kec_bind_fe`. Which primitives you bind
   into a context is what controls what that context can do.
4. Write carts and screens against Core plus those primitives.

See [ffi-bridge.md](ffi-bridge.md) for the C side.
