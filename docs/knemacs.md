---
title: knEmacs
description: The text editor built into the kec CLI — open it with `kec nemacs`, type, move, and save. Keybindings, the modeline, and how it works.
---

knEmacs is the text editor that ships inside the `kec` binary. It is a small,
Emacs-flavored terminal editor: open a file (or an empty scratch buffer), type
into it, move the cursor with the usual control keys, and save. It runs on a
normal computer — no KN-86 hardware required — and is the same editor the
handheld exposes on-device.

## Open it

```sh
kec nemacs              # an empty *scratch* buffer — just start typing
kec nemacs FILE         # open FILE (created on first save if it doesn't exist)
kec edit FILE           # `edit` is an alias for `nemacs`
```

It takes over the terminal (raw mode, alternate full-screen draw) and restores it
on exit. **To leave, press `C-x C-c`** (hold <kbd>Ctrl</kbd>, tap `x`, tap `c`).

> **Run it in a real terminal.** knEmacs is interactive; piping keystrokes into it
> works for scripting and tests, but to actually use it you need a TTY.

## Keys

Notation is Emacs-standard: `C-f` means <kbd>Ctrl</kbd>+`f`; `C-x C-s` is a
two-key sequence (`C-x` then `C-s`).

| Key | Command |
|-----|---------|
| any printable character | insert it at point (self-insert) |
| `Enter` | newline |
| `Backspace` | delete the character before point |
| `C-d` | delete the character at point (forward) |
| `Tab` | indent — insert spaces to the next tab stop (width 2) |
| `C-f` / `C-b` | forward / backward one character (or `→` / `←`) |
| `C-n` / `C-p` | next / previous line (or `↓` / `↑`) |
| `C-a` / `C-e` | beginning / end of line |
| `C-Space` | set the mark (start of a region) |
| `C-w` / `M-w` | kill / copy the region (mark…point) |
| `C-k` | kill to end of line (the newline if at end of line) |
| `C-y` | yank (paste the most recent kill) |
| `C-/` / `C-x u` | undo (redo: `M-/`) |
| `C-x C-s` | save the buffer to its file |
| `C-x C-c` | quit |
| `C-h k` *key* | describe what *key* does (help) |
| `C-g` | quit the current action (keyboard-quit) |

Forward/backward motion wraps across line boundaries: `C-f` at end-of-line moves
to the start of the next line, and `C-b` at column 0 moves to the end of the
previous line. Vertical motion (`C-n`/`C-p`) keeps a **goal column**: it lands at
that column where the line is long enough and clamps to the end of shorter lines,
*without forgetting it* — so passing through a short line and reaching a longer
one returns you to the original column. A horizontal move (or an edit) sets a new
goal. Lines wider than the window **scroll horizontally** so point stays visible;
`Tab` inserts soft spaces (never a literal tab) so the cursor stays aligned to the
grid.

## The modeline

The top row is an inverse-video status bar:

```
 path/to/file.lsp *  L2 C1
```

- the buffer name (the file path, or `*scratch*`)
- a `*` when there are unsaved edits
- `L<row> C<col>` — the cursor's line and column (1-based)

The bottom row is the echo line: it shows messages like `Wrote path/to/file.lsp`
after a save, a help line after `C-h k`, or `… is undefined` for an unbound key.

## Saving and quitting

- `C-x C-s` writes the buffer back to its file (byte-exact, at any size) and
  reports `Wrote …`. A successful save clears the modeline `*`.
- A bare `kec nemacs` (no file) has nothing to save to — `C-x C-s` will say
  *"No file"*. Pass a path if you want to keep what you type.
- `C-x C-c` **prompts before discarding unsaved edits**. With a clean buffer it
  exits immediately; with unsaved changes it asks `Save modified buffer before
  quit? (y/n, C-g cancel)` — `y` saves and exits, `n` exits and drops the edits,
  `C-g` cancels and returns you to the buffer. (A modified `*scratch*` with no
  file warns that the changes will be lost.)

## How it works

knEmacs follows the lesson of [rxi/lite](notes/field-notes-rxi-lite.md) and Emacs:
**the buffer is text** — lines of characters with a point (cursor) — and
*structure* (paren-matching, s-expression motion) is a lens computed on top, never
the representation. So opening Lisp source shows it as source, and you edit it
left-to-right like any text editor.

The split between the C host and the Lisp tier is deliberately thin:

- **The C host** (`cli/main.c`) owns only the terminal: raw mode, reading
  keystrokes, normalizing them to Emacs notation (`C-f`, `<up>`, `C-x C-s`), and
  file I/O. It knows no keybindings of its own.
- **The editor tier** (`editor/*.lsp`, an on-demand library — see
  [ADR-0002](adr/ADR-0002-editor-repl-extended-library-tier.md)) owns everything
  else. The text buffer is `editor/32-text.lsp`: a *line zipper* (the lines above
  point in reverse, the current line, the lines below, and a column), so every
  keystroke is an O(1) splice of one line or a shuffle of one line between the two
  stacks. The renderer (`text-screen`) lays out the modeline, a vertically
  scrolled text window, and the echo line, then parks the cursor at point.
- **The keymap is data** (`editor/55-bindings.lsp`): a table mapping a key string
  to a command. The host normalizes a keystroke, asks the table what it resolves
  to, and dispatches. Rebinding is a data edit, not a code change.

## Scope and roadmap

knEmacs today is the **minimal functional editor**: open, type, move, save. It is
intentionally small, and some familiar Emacs features are not built yet:

- **Structural ("paredit") editing** — `kill-sexp`, slurp/barf, wrap. The plan is
  to reintroduce the s-expression *zipper* as a command *lens* over the text
  (parse the current form → operate → reprint), i.e. a "lisp-mode", rather than as
  the buffer itself.
- **Undo/redo** is built — command-based (it stores the inverse of each edit, not
  whole-buffer snapshots), so it stays cheap on large files. `C-/` (or `C-x u`)
  undoes; `M-/` redoes; consecutive typing coalesces into one step.
- **Mark, region, kill & yank** are built — `C-Space` sets the mark; `C-w`/`M-w`
  kill/copy the region; `C-k` kills to end of line; `C-y` yanks. There is a
  bounded kill ring; `M-y` (yank-pop) is not built yet, and the mark is a plain
  position (not adjusted by edits made before a kill).
- A **minibuffer / `M-x` command-by-name**, **completion**, **`M-y` yank-pop**,
  and **multiple buffers** are all deferred.

The separate `kec repl` surface (a structural Lisp prompt) is unrelated to the
text editor and continues to use the s-expression zipper directly.
