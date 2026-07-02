---
title: "ADR-0005: Pure Math (trig) and Monotonic Time Primitives"
description: Accepted addition of always-on host primitives — sin/cos/tan/atan2 and a monotonic (now) clock — plus pi/tau Core constants, with a documented single-precision accuracy contract. Peers of the existing sqrt/pow/clock; no profile gate.
---

- **Status:** Accepted
- **Date:** 2026-06-27
- **Deciders:** KEC Lisp maintainers
- **Supersedes / superseded by:** —
- **Task:** GWP-641 (PR1 of the host-capabilities sprint)

## Context

An ASCII-animation experiment (`experiments/emacs-animation/`, the Dan-Torop
translation + an amber `emacs-fireplace`) surfaced four host capabilities the
language was missing. This ADR covers the two **pure, low-risk** ones; the host
input + idle-timer seam is ADR-0006 (lands with PR3 of this sprint).

The experiment had to **approximate `sin`** in Lisp (a Bhaskara parabola) because
the host exposed no trig, and it measured frame delays with **`clock`** — which
is *CPU* time (`clock()/CLOCKS_PER_SEC`), not wall time. Both are real gaps for
any procedural/geometry/CRT math and for timing.

The host math surface already had `mod`/`floor`/`ceil`/`round`/`abs`/`sqrt`/`pow`
as unconditional primitives (`host/host.c`), and `clock`/`rand` in the any-profile
"System" group. `<math.h>` and `<time.h>` are already included; `libm` is already
linked. So the additions are additive C wrappers with no new dependency.

## Decision

Add, in `host/host.c`:

- **Trig:** `sin`, `cos`, `tan` (one numeric arg, **radians**) and `atan2`
  (two args `(y x)`, like C; resolves the full `-pi..pi` range). Each computes in
  `double` and narrows to `fe_Number` on return — the exact pattern of `h_sqrt`.
- **`now`:** monotonic elapsed seconds via `clock_gettime(CLOCK_MONOTONIC)`.
  `clock` is **left unchanged** (CPU time, for profiling); `now` is the wall clock
  for timers/animation/elapsed-time.
  **Amended 2026-07-01 (GWP-584):** `now` measures from a **per-context baseline**
  captured when the interpreter opens, not from the raw `CLOCK_MONOTONIC` epoch
  (machine boot). `fe_Number` is a single-precision float, so boot-epoch seconds
  decay to ~62 ms resolution after ten days of uptime — unacceptable for the
  ADR-0006 editor timers on an always-on deck. Seconds-since-open keep
  sub-millisecond precision for the life of any session; the monotonic
  never-backward contract is unchanged.

Add, in Core (`core/15-math.lsp`, slotted into `CORE_SRCS` after `10-list`):

- **`pi`** and **`tau`** as constants (`define`), not a `(pi)` cfunc — a bare
  constant reads more naturally and `kec_bind_fe` registers cfuncs only.

### Tier placement — always-on, not FULL-gated

All five (`sin`/`cos`/`tan`/`atan2`/`now`) are registered **before** the
`if (profile == KEC_PROFILE_FULL)` gate, beside `sqrt`/`pow`/`clock`. The real
tier line in this codebase is "touches the host filesystem / process environment
vs. not" (`host/host.h`). Trig is referentially transparent and touches no host
resource; `now` is a clock read, no more capability-sensitive than the existing
any-profile `clock`. FULL-gating them would deny carts/missions (which run in
tighter-than-FULL firmware tiers) the geometry they need.

### Accuracy contract — single-precision

`fe_Number` is a single-precision `float`. Every math wrapper computes in `double`
and narrows on return, so:

- `pi` handed back is float-rounded (`3.1415927`), good to ~7 digits.
- `(sin pi)` is `~1e-7`, **not** exactly `0`.

This is fine for gameplay/CRT geometry and **unsafe for high-iteration
accumulation**. Tests assert with an **epsilon**, never exact `(is …)` equality
(`tests/core/math.lsp`, `tests/core/time.lsp` — invariants/lower-bounds only,
never an upper time bound, which a loaded CI runner would flake).

## Consequences

- The experiment's `anim-sin`/`anim-cos` now delegate to host `sin`/`cos`; its
  `anim-delay` measures with `now`. The Bhaskara approximation is removed.
- `host/host.c` is the portable layer the KN-86 firmware vendors, so these land
  **device-wide** — intended: the firmware gets the same geometry/time for free
  (the device implements `CLOCK_MONOTONIC` natively).
- No blocking `sleep` is added (it would stall the single-threaded cooperative
  loop). Waiting is expressed via `now`-spin-wait today and the poll-timeout
  timer in ADR-0006.
- No new `#include`, no link changes.
