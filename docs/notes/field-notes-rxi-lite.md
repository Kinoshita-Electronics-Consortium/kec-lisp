---
title: "Reference Implementation: rxi/lite"
description: rxi's lite editor as the runnable companion reference for knEmacs — a thin C core + a scripting-language userland that *is* the editor.
---

> A **reference implementation** for **knEmacs** (the KN-86 on-device editor) — a
> thing to *study*, not a source to port. Where
> [field-notes-emacs.md](field-notes-emacs.md) mines the GNU Emacs *manual* (the
> accumulated wisdom) and
> [field-notes-writing-gnu-emacs-extensions.md](field-notes-writing-gnu-emacs-extensions.md)
> mines *how to program one in Lisp*, **[rxi/lite](https://github.com/rxi/lite)**
> (MIT) is the *runnable minimal skeleton* of the exact architecture knEmacs
> targets: a thin C platform under an editor written almost entirely in a small
> scripting language. By the same author as **Fe** (the kernel under KEC Lisp), so
> it is kindred to the KEC stack by construction.

## Why it's the reference

lite is the thin-core-scripted-editor thesis **as a number: ~80% Lua / ~20% C.**
The C core is the *platform* (window, software renderer, font via stb_truetype,
filesystem/process); *everything editor* — the document/buffer model, views,
commands, keymap, the fuzzy command palette, syntax highlighting, plugins — is the
scripting userland. That is precisely the knEmacs split: a thin **firmware seam**
(C: `render_bitmap`, input, buffer/marker primitives, the FFI) under a **KEC-Lisp
userland** (modes, commands, keymaps — see the gap-analysis **N-A** column in the
extensions notes). lite is the worked example of *where to draw that line*, and the
80/20 ratio is the target: push almost everything to the scripting layer.

The Emacs manual shows the *what/why* across a huge mature codebase where the
skeleton is hard to see; lite shows the *how* in a handful of readable files. Read
them together.

## What to read, mapped to the knEmacs build order

- **`data/core/command.lua` + `data/core/keymap.lua`** — commands are named entries
  in a table; the keymap maps a stroke → a command name; `command.perform(name)`.
  The Emacs keys→named-command→function model in ~two tiny files — the field-notes'
  MVP step 1 (the command/keymap core), made concrete.
- **`data/core/commandview.lua`** — the fuzzy command palette / file finder: the
  **M-x / ido / Spotter** surface (the committed completion grammar) as one small,
  readable file. The single best minimal reference for it.
- **`data/core/doc/` + the highlighter** — buffer = lines; tokenize/highlight only
  the visible region (the JIT-fontify lesson) — the knEmacs buffer + font-lock model
  in working code.
- **The plugin model** (`data/user/init.lua`, plugin hooks; the
  [lite-plugins](https://github.com/rxi/lite-plugins) repo) — extend without
  patching core (the hooks lesson), runnable.
- **`src/` (the thin core)** — the C/script boundary itself: what rxi kept in C
  (renderer, font, system) vs. pushed to script. The concrete reference for the
  KN-86 firmware-seam-vs-KEC line.

## Caveats — read it through the device filter

- **Lua ≠ Fe** — a *design* reference, not portable code. The structure ports
  cleanly (both are tiny embeddable scripting languages; lite's command / keymap /
  palette are Lisp-shaped data you'd re-express in KEC trivially), but the syntax
  does not.
- **Desktop assumptions** — lite assumes a mouse, color themes, proportional fonts,
  tabs, and a large screen. knEmacs is 34-key, monochrome, 8×8, 128×75; apply the
  same filtering the Emacs field notes already do (no mouse, monochrome faces,
  narrow grid, …).
- **lite ships its own renderer** — take the *architecture*, not the rendering;
  KN-86's renderer is the native framebuffer (ADR-0036, in the kn-86 repo).

## The rxi lineage

KN-86's software stack is, not coincidentally, rxi-shaped: **Fe → KEC Lisp**
(kernel, vendored), **lite's architecture → knEmacs** (thin C + scripted editor),
and **[microui](https://github.com/rxi/microui)** is a candidate for
*emulator-side dev tooling* + its immediate-mode **command-list** pattern (declare
→ command buffer → backend renders), though its mouse-widget paradigm cuts against
the device's keyboard-modal grain. The whole toolkit shares the KN-86 ethos: tiny,
embeddable, no-malloc, do-one-thing-well.

---

*Captured as a reference implementation (not an ADR) for the knEmacs
engine-promotion work — the kec-lisp editor tier (the ADR-0046 follow-on, in the
kn-86 repo). Companion to [field-notes-emacs.md](field-notes-emacs.md) and
[field-notes-writing-gnu-emacs-extensions.md](field-notes-writing-gnu-emacs-extensions.md).*
