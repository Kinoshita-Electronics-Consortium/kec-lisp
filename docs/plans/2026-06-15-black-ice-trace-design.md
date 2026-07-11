---
title: BLACK ICE TRACE Design
description: Design notes for the BLACK ICE TRACE KEC Lisp example game.
---

## Concept

BLACK ICE TRACE is a turn-based terminal hacking game written in KEC Lisp. The
player breaks into a small corporate network, steals enough data, and jacks out
before trace reaches 100. The game is intentionally command driven so it fits
the current host primitives: printed output, command-line args, strings, and
file-backed state.

## Rules

The run contains five network nodes. Each node is an alist with a name, security
rating, data value, ICE rating, and status. Status progresses from `:unknown` to
`:scanned`, `:rooted`, and `:looted`.

The player is an alist with trace, stealth, credits, turn count, current node,
and a jack-out flag. Each command consumes a turn unless the game is already
over:

- Scan reveals a node and adds low trace.
- Crack attempts to root the current node, with security and ICE affecting risk.
- Siphon steals data from a rooted node.
- Spoof spends stealth to reduce trace.
- Pivot moves to another node.
- Jack out ends the run and wins only if the player has enough credits.

The player wins by jacking out with at least 300 credits. The player loses if
trace reaches 100 before jacking out.

## Implementation Shape

The game will be split into a small reusable library and a runner:

- `examples/black-ice-trace-lib.lsp` defines pure state helpers, render helpers,
  command application, and dashboard rendering.
- `examples/black-ice-trace.lsp` loads the library, applies one command from
  `args`, prints a dashboard, and saves state for the next invocation.
- `tests/examples/black-ice-trace.lsp` exercises deterministic helpers and a
  short scripted victory/loss path.

The library uses alists as records because, at the time of this plan, KEC Lisp
had no vectors, structs, or hash tables. (Vectors and hash tables landed six
days later in ADR-0003; the example intentionally stays on alists.) Lists are
short enough that linear lookup is fine and keeps the example idiomatic for
Core-only code.

## Expected Language Friction

The first version avoids raw keyboard controls, screen clearing, cursor
positioning, sockets, and a continuous stdin prompt. Those would make the game
feel more like a live TUI, but the current standalone host is better suited to a
stateful command loop driven by repeated CLI invocations.
