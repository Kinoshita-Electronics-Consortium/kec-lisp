# ASCII animation experiments in KEC Lisp

A playground translating Dan Torop's [Emacs Lisp animations](https://dantorop.info/project/emacs-animation/)
teaching project into KEC Lisp. Torop teaches animation to non-programmers by
moving ASCII characters around an Emacs *buffer* with a dead-simple loop:

```elisp
(while t
  (erase-buffer)        ; clear the frame
  (insert "...")        ; draw
  (sit-for 0.2))        ; wait
```

KEC Lisp has no buffer, no `sit-for`, no `read-event`. So these experiments
animate the **terminal** directly: ANSI cursor control + a spin-wait clock + a
mutable char canvas. The point is to find out what KEC Lisp can already do, what
it can't, and what a reusable "animation" vocabulary should look like.

## Run it

Build the CLI, then run a demo **from the repo root, in a real terminal**:

```sh
cmake -S . -B build && cmake --build build
./build/kec run experiments/emacs-animation/02-sine-wave.lsp
```

> Run it in a TTY. Frames flush on the newline at the end of each frame, and that
> only happens line-by-line on a terminal — piping into a file block-buffers and
> you'll see nothing until it finishes. Each demo self-terminates after a fixed
> number of frames (no `C-c` needed).

| Demo | What it shows | Torop source |
|------|---------------|--------------|
| [`01-line-down.lsp`](01-line-down.lsp) | a bar walks down the screen — the raw idiom, no canvas | Part 4 |
| [`02-sine-wave.lsp`](02-sine-wave.lsp) | a travelling sine wave | Part 4 ("mathematical movement", `(sin (/ y 7.0))`) |
| [`03-drunkard.lsp`](03-drunkard.lsp) | a `*` random-walks leaving a `.` trail | Part 7 (drunkard's walk) |
| [`04-bounce.lsp`](04-bounce.lsp) | a ball carries velocity and reflects off walls | Part 7 ("runner" momentum) |
| [`05-marquee.lsp`](05-marquee.lsp) | a scrolling text ticker | — (echo-line / CIPHER-LINE relevant) |
| [`06-fireplace.lsp`](06-fireplace.lsp) | an amber fireplace in shade glyphs | [johanvts/emacs-fireplace](https://github.com/johanvts/emacs-fireplace) |

[`anim.lsp`](anim.lsp) is the shared library every demo loads.

## What translated cleanly (the proven primitives)

These all work today with the stock `kec` binary, no C changes:

| Torop / Emacs | KEC Lisp translation | Mechanism |
|---|---|---|
| `erase-buffer` + `insert` | a **canvas** — `make-canvas`, `draw-char`, `clear-char`, `canvas-clear!` | mutable `vector` of 1-char strings |
| frame paint | `render-frame` / `canvas->string` | `ESC[H` home + overwrite (low flicker, no full clear per frame) |
| the `while` + `sit-for` loop | `anim-loop` | the one shared driver: `(anim-loop n delay body)` |
| `(1- (random 3))` → −1/0/+1 | `(- (rand-int 3) 1)` | identical distribution |
| velocity `dx`/`dy` integration | plain arithmetic + wall-reflection | verified to stay in bounds |
| `(min … width) (max … 1)` clamping | `clamp` | `(max lo (min hi v))` |

A nice KEC-specific tailwind: **top-level `let` binds globally** (a deliberate
kernel delta), so a demo can `(let x …)` at the top and a frame lambda can
`(set x …)` it — the closure mutates the global directly. That's why the demos
read so close to the Emacs originals.

## What's missing (the gaps this experiment surfaced)

Four things blocked a faithful port. Three I worked around in Lisp; one is a hard
wall. **This is the real output of the experiment** — the shopping list for the
host (`host/host.c`) if animation graduates from playground to feature.

1. **No `sleep` / wall-clock.** The only time primitive is `clock` (CPU seconds).
   `anim-delay` spin-waits on it, which pins one core at 100% for the whole
   animation. Fine for a demo, wrong for anything real. → *want a host
   `(sleep secs)` (nanosleep) and a monotonic `(now)`.*
2. **No `sin`/`cos`/`pi`.** Torop's smoothest lesson (`(sin (/ y 7.0))`) has no
   host equivalent. `anim-sin` approximates it in Lisp (Bhaskara parabola + a
   Q=0.225 refinement; exact at 0/±π⁄2/±π, ~0.7% error mid-curve — verified
   `anim-sin(π/4)=0.708` vs true `0.707`). Works, but every curve-based animation
   pays for it. → *want host `sin`/`cos` (and `pi`).*
3. **No keyboard input.** `read-event` drives Torop's Parts 7–8 (the interactive
   walker, Pong). KEC Lisp's FULL profile exposes file I/O but **no `read-char` /
   non-blocking poll**, so every *interactive* animation is blocked. `04-bounce`
   is the autonomous stand-in (physics without the keys). → *want a host input
   seam: blocking `(read-key)` and a timeout form like Emacs's
   `(read-event nil nil 0.1)`.*
4. **No explicit flush.** `princ` relies on TTY line-buffering; there's no
   `(flush)`. Works on a terminal, invisible through a pipe. → *minor: a host
   `(flush)` would make output device-independent.*

## The fireplace, on KN-86 terms

[`06-fireplace.lsp`](06-fireplace.lsp) ports [emacs-fireplace](https://github.com/johanvts/emacs-fireplace)
with two deliberate substitutions that make it a KN-86 artifact rather than a copy:

- **One colour, not two.** The original uses an outer "orange red" face and an
  inner "dark orange" core. KN-86 is monochrome — a single foreground on black
  (Canonical Hardware Spec). So the fire is rendered entirely in canonical amber
  `#E6A020` via a truecolor SGR (`ESC[38;2;230;160;32m`) on a black background.
- **Intensity as glyph density, not hue.** The heat the original carried in colour
  we carry in a **shade ramp** — `" ░▒▓█"` (U+2591–2588). A hot flame core is `█`,
  cooling outward and upward through `▓ ▒ ░` to black. This is the "blocks and
  shaded blocks instead of two colours" idea, and it's a natural fit for the
  device's CP437 glyph set.

The motion is a **heat field** (the "doom fire" propagation), which suits the ramp
better than the original's literal flame-stripes: a hot base is reseeded each frame
at several flame x-positions (emacs-fireplace's `fireplace--flame-pos`), and heat
climbs upward with random cooling and lateral drift, so flames lick and flicker on
their own. Two tuning lessons worth keeping (both were bugs first):

- **Decouple cooling from drift.** Sharing one random draw for both made cooling
  average ~0.33/row, so flames never faded — a solid wall of noise. An independent
  cooling draw (avg ~1/row) gives flames that taper and leave black sky for sparks.
- **A dim, not bright, ember bed.** Seeding the whole base row hot erased the gaps
  between flames. A faint `░` floor reads as glowing coals while letting the seeded
  flame columns stand out as distinct flames.

This is also the demo that most wants the host work below: it spin-waits one core
for the frame delay, sets amber with a raw escape (no palette abstraction yet), and
can't live *inside* knEmacs without an idle-timer. It's the strongest argument that
the next step is host primitives, not more Lisp.

## …and the knEmacs gap specifically

The user ask was "animations **in knEmacs**." Worth being precise: these run as
standalone `kec run` scripts, **not inside the editor**. knEmacs's main loop is
C-driven (`cli/main.c`) and **blocks** on a keystroke read — it only redraws in
response to a key. To animate *inside* the editor you'd need the host to grow an
**idle-timer / non-blocking poll** (Emacs's `run-with-timer` is exactly this):
the loop waits up to N ms for a key, and on timeout fires a registered Lisp
redraw thunk. That single seam — a timed poll — unlocks both #3 (interactive
animation) and in-editor animation at once. It's the highest-leverage host
change on this list.

## The design system, as it crystallized

What survived the experiment is a small four-layer vocabulary. If this becomes
real, this is the shape to formalize (and the natural home is a provide-gated
`editor/`-style module, loaded on demand like the rest of the editor tier):

```
ANSI layer     ansi-home / ansi-clear / ansi-goto / cursor hide-show
  └ timing     anim-delay            (→ host sleep)
  └ math       anim-sin / anim-cos / clamp   (→ host trig)
  └ canvas     make-canvas / draw-char / clear-char / canvas-clear! / render-frame
       └ loop  anim-loop  ← the one driver; a demo is just a frame-body lambda
```

The canvas + `anim-loop` split is the keeper: **a demo is a single
`(fn (i) …)` that draws frame `i`**, and the library owns clearing, timing,
cursor, and teardown. Everything Torop teaches across nine lessons reduces to
"write the frame body." That's the abstraction worth shipping — once the host
gives us real `sleep`, `sin`, and a timed key-poll to stand it on.
