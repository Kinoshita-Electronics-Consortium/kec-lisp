---
title: "ADR-0006: Host Input + knEmacs Idle-Timer Seam"
description: Accepted architecture for keyboard input and an idle-timer in knEmacs — CLI-bound read-key/poll-key, a host-owned poll()-with-timeout loop, and a clock-free Lisp timer registry. The C host keeps the event loop; timing enters as a seam, not a loop inversion.
---

- **Status:** Accepted
- **Date:** 2026-06-27
- **Deciders:** KEC Lisp maintainers
- **Supersedes / superseded by:** —
- **Builds on:** [ADR-0002](ADR-0002-editor-repl-extended-library-tier.md) (editor tier), [ADR-0005](ADR-0005-pure-math-and-monotonic-time-primitives.md) (`now`)
- **Tasks:** GWP-642 (input, PR2), GWP-643 (idle-timer, PR3)

## Context

The same ASCII-animation experiment behind ADR-0005 surfaced two harder gaps:
no way to **read a keystroke** from Lisp (every interactive animation — Torop's
walker, Pong — was blocked), and the knEmacs editor loop **blocks** on a
keystroke (`cli/main.c do_nemacs`), so nothing animates *inside* the editor: it
only redraws in response to a key. Emacs solves the latter with `run-with-timer`
+ an idle event loop.

Both touch the boundary between the C host and the Lisp tier, and `host/host.c`
is the portable layer the KN-86 firmware vendors — so the decision is as much
about *where* the code lives as *what* it does.

## Decision

Three pieces, with the C host keeping ownership of the event loop:

### 1. Keyboard input is a CLI host seam, not a portable primitive

`read-key` (blocking, → byte or `nil` at EOF) and `poll-key` (timeout, → byte or
`nil`) are bound from **`cli/main.c`** (the shared `cli_open`), not from
`host/host.c`. Raw-mode / `poll()`-on-stdin is terminal-specific; the device has
no TTY (input is USB-HID / evdev). The portable artifact is the **Lisp-facing
contract** — a module that calls `(poll-key 0.05)` runs unchanged on the laptop
and the device, because the firmware registers the *same names* over its own
input through the same `kec_bind_fe` seam (see `docs/ffi-bridge.md §4`). Binding
from `cli_open` also makes them reachable from `kec run`, which is what makes a
pipe-fed conformance test possible.

The editor's keystroke reads were converted from `getchar()` to `read(2)` (a
`rd1()` helper), because stdio buffering is invisible to `poll()`: a byte
buffered by stdio would make the idle-timer's poll-timeout fire spuriously.
Under raw mode (`VMIN=1`/`VTIME=0`) `read(2)` blocks for exactly one byte, so
loop semantics are unchanged.

### 2. The idle-timer is a poll-with-timeout, not a loop inversion

The `do_nemacs` blocking read becomes: ask the Lisp registry how long until the
next armed timer, `poll()` stdin for that long; on timeout, fire the due thunks
and repaint; otherwise read the waiting key. **The C host still owns the loop.**
We deliberately did *not* invert the loop into Lisp (which would have made input
+ timing Lisp-driven and warranted a much larger change) — the conservative,
device-safe default keeps the proven editor intact.

Two invariants protect the existing editor:

- **No-timer path is byte-identical.** With nothing armed the registry returns a
  poll timeout of **`-1`** (block forever), so the loop behaves exactly as it did
  before timers existed. `tests/cli/nemacs-smoke.sh` (the full
  keystroke→saved-file sequence) passes unchanged.
- **Modal sub-loops stay blocking.** `confirm_quit` and `isearch` run their own
  reads; timers pause during a prompt, matching Emacs. Only the one main-loop
  read gained the poll wrapper.

### 3. The timer registry is clock-free Lisp

`editor/72-timer.lsp` owns scheduling in **abstract seconds**: `run-with-timer`,
`cancel-timer`, `timers-poll-ms`, `timers-advance!`. Every entry point takes the
current time `now` as an **argument** — the *host* owns the clock (`now`, ADR-0005)
and passes it in. This keeps the registry pure and **deterministically testable
against a mock clock** (`tests/editor/timer.lsp`, 27 checks, no real time), and
lets the firmware drive it from whatever clock it has. `timers-advance!` snapshots
the due set and rebuilds the registry *before* firing any thunk, so a thunk may
`cancel-timer`/`run-with-timer` mid-fire without corrupting the walk.

A one-shot **`KN86_NEMACS_INIT`** hook (a Lisp expression evaluated once at editor
startup) lets a session arm timers / preload config; the idle-timer conformance
test uses it to prove a timer fires between keystrokes across an idle gap
(`tests/cli/idle-timer-smoke.sh`).

## Consequences

- Animation can run inside knEmacs: an armed timer fires on idle and repaints
  (demonstrated — a repeating timer inserts text between keystrokes).
- **No blocking `sleep`** anywhere (ADR-0005 reaffirmed): the timer's
  poll-timeout *is* the wait, so the single-threaded cooperative loop (input,
  redraw, and on-device the coproc UART + 44.1 kHz audio callback) is never
  stalled. On-device, frame-rate/power policy gates `timers-advance!` behind power
  state — a firmware concern, not the library's.
- `read-key`/`poll-key` read raw bytes; multi-byte keys (arrows, Meta) are the
  caller's to assemble, mirroring how `do_nemacs`'s `norm_key` already works.
- The device firmware satisfies the same two seams (input, timer-advance) with
  its own host code; only the Lisp contract is shared.
- **Spin-safe by construction.** A non-positive `repeat` normalizes to a one-shot
  (in KEC `0` is truthy, so an un-guarded `0` would re-arm to "now" forever); the
  host floors its poll interval to 10 ms (a genuinely sub-millisecond repeat ticks
  at ~100 Hz, never a 0 ms busy-loop) and caps it at one day (so a far-future delay
  can't overflow the float→int cast); and the host computes the timeout by an
  explicit eval that falls back to the blocking `-1` on any registry error or
  non-number — a broken timer thunk stops the timers, it never spins the editor.
  `poll-key` is likewise clamped and retries `EINTR` rather than reporting a
  spurious timeout.
