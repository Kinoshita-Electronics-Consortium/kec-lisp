---
title: "Field Notes: GNU Emacs Manual"
description: Reading notes from the GNU Emacs Manual mined for nEmacs (the KN-86 on-device editor) and a future desktop kec-lisp Emacs mode.
---

> Reading notes on the *GNU Emacs Manual* (17th ed., Emacs 24.5; Stallman et al.),
> mined for two KEC projects:
> 1. **nEmacs** — an Emacs *clone* built into the KN-86 handheld's nOSh runtime: a
>    constrained, on-device structural editor + REPL (ADR-0008 UX, ADR-0016
>    context-polymorphic dispatch + Nokia multi-tap). Amber-on-black terminal,
>    128×75 cell grid (often an 80×25 view), no mouse, no graphical frames, 34-key
>    split keyboard with modifier layers, arena-bounded / GC-stack-limited memory.
> 2. **kec-lisp mode** — eventually a real desktop GNU Emacs major mode for editing
>    `.lsp` KEC Lisp files: font-lock, indentation, sexp/paren editing, an
>    inferior-`kec` REPL.

**The two big takeaways up front:**

- **For nEmacs:** *Emacs is its extension language.* "Most of the editing commands
  in Emacs are written in Lisp; the few exceptions could have been written in Lisp
  but use C instead for efficiency" (Introduction, p. 5). Keys don't have meanings —
  **keys are bound to named commands, and commands are Lisp functions** (§2.3, p. 12).
  That single indirection (key → named command → Lisp function, resolved through
  layered keymaps that are themselves data) is the blueprint for building nEmacs over
  KEC Lisp, and it is the native answer to ADR-0016's context-sensitive keys.
- **For kec-mode:** *Emacs already solved Lisp editing.* A programming major mode is a
  small bundle — syntax table + indentation function + font-lock keywords + defun
  delimiters + comment vars — and an inferior-process REPL is a solved problem
  (comint / `run-lisp`). Most of kec-mode is wiring, not invention.

**How to read this.** Each note cites a **printed book page** (`p. NN`). Tags:
**Goal** = nEmacs / kec-mode / both. **Applicability** = **Direct** (adopt as-is) /
**Adapt** (transfers but must change for the device constraints) / **Aspirational** /
**Avoid** (GUI/desktop-only — skip for nEmacs). Source: `emacsman.pdf` (611 pp.).
PDF↔book offset: PDF page = book page + 22.

---

## Top cross-cutting lessons

### A. The nEmacs architecture (load-bearing)

1. **Keys → named commands → Lisp functions, via keymaps that are *data*** (§2.3 p. 12; §33.3 pp. 429–430).
   Make nEmacs's key→command table a KEC data structure mapping input events to named
   KEC functions, **not** a C `switch`. This is what makes the editor reprogrammable
   live and is the substrate ADR-0008 assumes.

2. **Layered keymaps are the answer to context-sensitive keys** (§33.3.3 p. 430).
   Lookup resolves minor-mode maps → major-mode (local) map → global map; first
   whole-sequence match wins. Model each surface/mode as a local keymap and overlay
   transient states (multi-tap entry, seed-capture, isearch) as higher-priority maps.
   The *same* physical key (TERM) means different things because a higher-priority map
   shadows it — no god-switch. **Prefix keys are themselves keymaps** (§33.3.2), giving
   a 34-key board unlimited reach via a leader model.

3. **The buffer is the unit of organization; buffer-local variables are the substrate** (§16 p. 147; §33.2.3 p. 423).
   A buffer = text + its own point + major mode + a local-variable bag. Build one
   buffer-local-variable mechanism and modes, read-only, and indentation policy all
   fall out of it. The `.lsp` editor and the REPL become sibling buffers with
   independent state.

4. **Major mode = one exclusive personality; minor modes = composable layers; hooks = the extension seam** (§20 pp. 199–201).
   nEmacs gets a `kec-lisp-mode` and a `repl-mode`, each owning its keymap + indent.
   Feature layers (paren-match, auto-indent, multi-tap overwrite) are minor modes
   toggled per buffer. Every mode runs a `<mode>-hook` so config/carts add behavior
   *without patching the mode* (§33.2.2 p. 422).

5. **The minibuffer is the editor reused as a prompt surface; completion is the multi-tap force-multiplier** (§5 pp. 26–32).
   Don't build a separate input widget — reuse the edit buffer in a reserved row.
   **Completion (TAB / complete-to-next-hyphen) is the single biggest win**: typing 2–3
   chars + TAB to fill a hyphenated KEC name turns slow multi-tap entry into a few
   keystrokes. Candidate sets are *data* the command supplies (bound symbols, loaded
   carts, file names).

6. **M-x is the pressure valve: every command reachable by name** (§6 p. 36).
   A 34-key device physically cannot bind everything. Bind the hot commands
   (ADR-0016), and let the long tail live behind `M-x` + completion. The echo-area
   "this also runs on key X" hint doubles as passive discovery.

7. **Self-documentation falls out for free** (§7 pp. 37–41).
   `describe-key` / `describe-function` / `where-is` / `apropos` are just introspection
   over the same data the editor runs on (named functions with docstrings;
   introspectable keymaps). If nEmacs commands are named KEC functions and keymaps are
   KEC data, the whole help system is a handful of introspection calls — *attach
   docstrings to functions and you get help nearly for free.* (Ties directly to the
   KEC-Lisp introspection ideas in [field-notes-amop.md](field-notes-amop.md).)

8. **The kill ring / mark ring / registers are bounded in-memory rings — no OS clipboard needed** (§9 p. 55; §8.4 p. 48; §10 p. 64).
   The device has no system clipboard; Emacs's model *predates and stands alone from*
   one. A fixed-capacity ring of N text blocks + a "last-yank" index gives cut/copy/paste
   **with history**. Size each ring to the arena budget. Registers (a char→tagged-union
   table) are a huge power feature per byte.

9. **Linear undo with a hard byte ceiling** (§13.1 pp. 109–110).
   One stack + a "last command was not undo" boundary flag; "redo" is undoing the undos.
   Far cheaper than a branching tree and a perfect fit for arena memory: cap undo bytes,
   discard oldest first, tie the discard to arena-reset boundaries. **Coalesce
   insertions** — record undo at word/commit boundaries so multi-tap entry isn't N
   separate undos.

10. **Keyboard macros = record the command stream and replay it** (§14 pp. 114–118).
    Possible *only because* every action is a named command on one uniform input→command
    pipeline. A tiny keyboard makes this *more* valuable. nEmacs gets macros nearly free
    if input dispatch can record/replay the command stream; named macros become
    first-class commands (persist per-deck, like REPL history).

11. **Tiny-screen rendering discipline: narrowing, conservative scroll, JIT monochrome faces** (§11 pp. 73–84).
    *Narrowing* (restrict to the current defun) is the highest-value focus mechanism on
    80×25 — costs only a start/end restriction. *Conservative scroll* repaints the fewest
    cells (fits the ~20fps event-driven redraw). *Faces* are a **meaning→render
    indirection**: keep "this is a string," but lower face→pixels to the few monochrome
    attributes an 8×8 amber cell can express (dim, reverse, underline — **not** color),
    and warn that bold+reverse together can be illegible. *JIT-fontify only the visible
    ~2000 cells*, never the whole buffer.

### B. The kec-lisp-mode build manifest

12. **A programming mode is a syntax bundle** (§23.1 p. 240): derive from `prog-mode`;
    supply a **syntax table**, an **indentation function**, **font-lock keywords**, and
    **defun delimiters**; run a `kec-mode-hook`.

13. **Register on `.lsp` and claim it** (§20.3 pp. 202–204; §24.7 p. 279): add
    `("\\.lsp\\'" . kec-lisp-mode)` to `auto-mode-alist`. Note `.lsp` *already* defaults
    to `lisp-mode`, so kec-mode must claim it explicitly. Honor the file-local
    `-*- … -*-` mode line so a cart can pin its mode.

14. **Lisp indentation is computed from sexp nesting, never stored** (§23.3 pp. 243–245):
    TAB reindents from paren structure. Ship a small symbol→rule table giving
    body-style indent to KEC special forms (`def*`, `let`, `mac`, `fn`, quasiquote).

15. **Structural sexp/paren editing is the core** (§23.4 pp. 246–248): `forward/backward-sexp`,
    `kill-sexp`, `transpose-sexps`, `mark-sexp`, `up/down-list` — mostly free from
    `prog-mode`. Add **Show Paren** (highlight match) and consider **Electric Pair**
    (auto-close) so the keyboard never produces unbalanced source; `check-parens` before
    `kec build`.

16. **Cheap wins:** set `comment-start`/`comment-end`/`comment-start-skip` (`"; "` / `""`)
    and inherit all of `comment-dwim` (§23.5 p. 249); set `indent-tabs-mode` nil
    (spaces only, §21.3 p. 207).

17. **The REPL is comint + the `kec` CLI** (§24.11 pp. 279–280): kec-mode is the
    `lisp-mode`/**inferior-process** archetype (send forms to a separate `kec` process),
    *not* the `emacs-lisp-mode` self-eval archetype. Set `inferior-lisp-program` to
    `kec repl`, run under comint, rebind `send-last-sexp`/`send-defun`/`send-region`/
    `send-buffer` onto the CLI's `eval`/`run` subcommands. **nEmacs is the opposite
    case** — its interpreter is in-process, so it behaves like `emacs-lisp-mode`
    (eval in its own image; `*scratch*`-style `C-j` eval-and-insert fits the amber grid).

18. **Completion from the *live* environment** (§23.8 p. 254): because KEC Core is loaded
    into a running `kec_State`, the best completion source is the live process's symbol
    table (query the inferior REPL), not static parsing. nEmacs has the interpreter
    in-process, so it can complete straight from the live environment.

---

## Foundational notes — Introduction & Chapters 1–3 (book pp. 5–15)

The opening chapters define what an Emacs *is*: four properties (advanced,
self-documenting, customizable, extensible), a screen model (frame / window / buffer /
point / echo area / mode line), and the keys-vs-commands indirection that the entire
architecture rests on.

### The four pillars — and "the editor is written in its own Lisp"
- **Where:** p. 5 (Introduction)
- **Insight:** Emacs is **advanced** (far more than insert/delete — controls subprocesses, indents programs, operates on chars/words/lines/sentences/paragraphs/pages *and* expressions/comments in programming languages), **self-documenting** (help commands describe any key/command/topic), **customizable** (alter behavior simply — e.g. tell the comment commands new delimiters, rebind cursor-motion keys), and **extensible** ("New commands are simply programs written in the Lisp language, run by Emacs's own Lisp interpreter… existing commands can even be redefined in the middle of an editing session, without having to restart"). "Most of the editing commands in Emacs are written in Lisp; the few exceptions could have been written in Lisp but use C instead for efficiency."
- **Why it matters:** This is the exact architecture bet for nEmacs over KEC Lisp, and it parallels KEC's own kernel(C)→core(Lisp) split: a small C substrate with the editor's behavior expressed in the embedded Lisp, commands as named Lisp functions, live-redefinable. Adopt "the editor is its extension language" as the nEmacs design law.
- **Goal:** nEmacs
- **Applicability:** Direct

### Frame / window / buffer are three distinct things
- **Where:** p. 6 (§1 "The Organization of the Screen")
- **Insight:** A *frame* is the whole terminal screen (on a text terminal Emacs occupies the entire screen and starts with one window); a *window* is a viewport showing a buffer (with a mode line at its bottom); a *buffer* is the text being edited. The selected window's buffer is the *current buffer*, where editing happens.
- **Why it matters:** nEmacs has exactly one frame (the device screen) and likely 1–2 windows, but keeping window (viewport) distinct from buffer (content) is what lets the editor and REPL show as stacked panes, or the same buffer appear twice. Bake the distinction in even if the v0 layout is single-window.
- **Goal:** nEmacs
- **Applicability:** Direct

### Point is between characters and belongs to the view
- **Where:** pp. 6–7 (§1.1 "Point")
- **Insight:** Point (the cursor) is the location where most editing takes effect; it sits *between* two characters, not on one. Each buffer remembers its own point; a buffer shown in several windows has a separate point per window.
- **Why it matters:** "Point belongs to the view, not the buffer" is the clean rule that lets two nEmacs panes scroll the same buffer independently. The between-chars model (vs on-a-char) simplifies insertion/motion semantics and should be nEmacs's representation.
- **Goal:** nEmacs
- **Applicability:** Direct

### The echo area is one multiplexed line: echo, messages, minibuffer
- **Where:** p. 7 (§1.2 "The Echo Area")
- **Insight:** The bottom line serves several purposes: *echoing* a multi-character command as you type it (single-char commands aren't echoed; multi-char ones echo after a ~1s pause to give confident users speed and hesitant users feedback), displaying error and informative messages (saved to a `*Messages*` log buffer), and hosting the *minibuffer*. `C-g` always escapes the minibuffer.
- **Why it matters:** nEmacs can multiplex a single reserved row (or the firmware Row 74) the same way: prompt input, transient messages, and key-echo all share it. The "echo the prefix after a pause" behavior is a cheap way to teach a 34-key chord/leader system to a hesitant operator without slowing a fluent one.
- **Goal:** nEmacs
- **Applicability:** Adapt

### The mode line is composable status data
- **Where:** pp. 8–9 (§1.3 "The Mode Line")
- **Insight:** The per-window mode line follows a format `cs:ch-fr buf pos line (major minor)`: a modified indicator (`--` unmodified, `**` modified, `%%`/`%*` read-only), position (`Top`/`Bot`/`nn%`/`All`), line number, the major mode name, and a list of active minor modes; indicators like `Narrow` and `Def` (macro recording) also appear. Its contents and appearance are customizable.
- **Why it matters:** The KN-86's firmware status (Row 0) and action (Row 74) bars are exactly a mode line: a fixed row assembled from independently toggleable fields (modified flag, position, major-mode name, active minor modes, `Narrow`/recording indicators). Model it as composable data, not a hardcoded string.
- **Goal:** nEmacs
- **Applicability:** Direct

### Keyboard-accessible menus via the echo area (digit-indexed)
- **Where:** pp. 9–10 (§1.4 "The Menu Bar")
- **Insight:** The graphical menu bar is mouse-oriented, but on a text terminal `tmm-menubar` (`M-\``, or `F10` with `tty-menu-open-use-tmm`) presents menu items *in the echo area*, each tagged with a letter/digit you type to select it.
- **Why it matters:** The graphical menu bar is **Avoid** (no mouse), but the digit-indexed echo-area menu is a reusable pattern for nEmacs: present a short numbered list and accept one keystroke — the same interaction grammar that suits completion candidates and query-replace on a tiny screen.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Keys, modifiers, prefix keys, and the ESC-as-Meta trick
- **Where:** pp. 11–12 (§2.1–2.2 "Kinds of User Input"; "Keys")
- **Insight:** Input is extended ASCII; modifiers (`Ctrl`, `Meta`/`Alt`) apply to any key including non-alphanumerics (`C-F1`, `M-LEFT`). Meta can be typed as a two-event `ESC` prefix (useful when no Meta key exists). A *key sequence* is one unit; a *complete key* invokes a command, a *prefix key* (`C-x`, `C-c`, `ESC`, `M-g`, `C-x 4`, …) waits for more input. The prefix-key list "is not cast in stone."
- **Why it matters:** Directly informs the Ferris Sweep's modifier-layer + leader design: nEmacs needs prefix keys (a leader model) to reach a large command set from 34 keys, and the ESC-as-Meta trick is the precedent for synthesizing a "Meta" from a layer when no dedicated key exists.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Keys have no meaning — *commands* do (the central indirection)
- **Where:** p. 12 (§2.3 "Keys and Commands")
- **Insight:** "Emacs does not assign meanings to keys directly. Instead, Emacs assigns meanings to named *commands*, and then gives keys their meanings by *binding* them to commands." Every command has a name; internally each is a Lisp *function*; bindings live in *keymaps*. "`C-n` has this effect *because* it is bound to `next-line`. If you rebind `C-n` to `forward-word`, `C-n` will move forward one word instead."
- **Why it matters:** THE foundational lesson. This indirection is what makes keyboard macros, self-documentation, completion, rebinding, and context-sensitive keys all possible and all *fall out of one mechanism*. nEmacs must be built this way over KEC Lisp; it is the root from which most other lessons here derive.
- **Goal:** both
- **Applicability:** Direct

### Persistent session accumulates context; exit is deliberately awkward
- **Where:** pp. 14–15 (§3.1–3.2 "Entering and Exiting Emacs")
- **Insight:** The recommended model is to start Emacs once and keep the session, because it accumulates valuable context — kill ring, registers, undo history, mark ring. Exit (`C-x C-c`) is a two-key sequence "to make it harder to type by accident," and offers to save modified buffers first. While in Emacs, the terminal's own kill/suspend characters are disabled — Emacs owns all keys.
- **Why it matters:** The KN-86 is always-on; nEmacs *is* a persistent session by nature, so the accumulated-context model (kill/mark rings, undo, history surviving across edits) is native. "Emacs owns all keys" is exactly nEmacs's relationship to the device — there's no host OS competing for input. Deliberate friction on destructive actions (save-before-exit, awkward exit chord) is a pattern to copy.
- **Goal:** nEmacs
- **Applicability:** Adapt

---

## Field notes by chapter

## Chapters 4 & 13 — Basic Editing; Fixing Typos (book pp. 16–25, 109–113)

These chapters define Emacs's core editing contract: text is a buffer with a single insertion point, graphic characters self-insert while every other key runs a named command, and a small motion vocabulary (char/word/line/buffer) is multiplied by a universal numeric/prefix-argument modifier. The fixing-typos chapter specifies the undo model — a per-buffer linear record where consecutive insertions group into one entry, "redo" is just undoing an undo after any intervening command, and undo memory is explicitly bounded — plus transpose and case commands purpose-built for the most common typing slips.

### Self-insert vs. command dispatch is the core input model
- **Where:** p. 16 (§4.1 "Inserting Text")
- **Insight:** "Only graphic characters can be inserted by typing the associated key; other keys act as editing commands and do not insert themselves." Insertion adds the char at point and advances point; non-graphic keys (e.g. DEL) run a bound command like `delete-backward-char`.
- **Why it matters:** The exact dispatch nEmacs needs over KEC Lisp — a key event either self-inserts a glyph or invokes a named command via a keymap. The 34-key Sweep + Nokia multi-tap layer must resolve a keypress to "graphic char to self-insert" vs. "command symbol to apply"; multi-tap means the same physical key produces different glyphs by timing, so the self-insert path is stateful in a way desktop Emacs's isn't.
- **Goal:** both
- **Applicability:** Adapt

### Point motion is a closed char/word/line/buffer vocabulary
- **Where:** pp. 17–18 (§4.2 "Changing the Location of Point")
- **Insight:** A small orthogonal set of named motion commands: `forward-char`/`backward-char`, `forward-word`/`backward-word`, `move-beginning-of-line`/`move-end-of-line`, `beginning-of-buffer`/`end-of-buffer`, plus screen-line `next-line`/`previous-line`.
- **Why it matters:** This four-tier granularity is the minimum motion API nEmacs should expose as KEC commands. With no mouse and 34 keys, word/line/buffer motion is primary navigation, not convenience — it carries the load a mouse would on desktop.
- **Goal:** nEmacs
- **Applicability:** Direct

### Numeric/prefix argument is a universal command modifier
- **Where:** pp. 23–24 (§4.10 "Numeric Arguments")
- **Insight:** Any command can take a numeric/prefix argument: `C-u`/`M-N`/`M--` supply a count; `C-u` alone means "four times" and stacks; negatives reverse direction; some commands only check *presence* of an argument, not its value.
- **Why it matters:** One uniform modifier multiplying every command keeps the command set tiny — critical with 34 keys. But the desktop encoding leans on a keypad / held-Meta-digit chords nEmacs lacks, and multi-tap competes for digit keys, so nEmacs must invent a distinct "enter prefix arg" gesture (a dedicated layer or a `C-u`-like key).
- **Goal:** nEmacs
- **Applicability:** Adapt

### Undo is a per-buffer linear record with grouped insertions
- **Where:** p. 109 (§13.1 "Undo"); p. 20 (§4.4)
- **Insight:** "Each buffer records changes individually." Usually one command = one undo entry, but consecutive character insertions group into a single record (and commands like `query-replace` split into several). Undo applies only to buffer text, never to point motion alone.
- **Why it matters:** The spec to implement for nEmacs's editor and REPL: a per-buffer change list with insertion-coalescing so multi-tap entry of one word isn't N undos. Record undo at word/commit boundaries, not per keystroke, or undo becomes uselessly granular.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Redo is "undo the undos" after any breaking command
- **Where:** p. 109 (§13.1 "Undo")
- **Insight:** No separate redo command. Any non-undo command breaks the undo sequence; the run of undos you just performed is itself pushed onto the record as one change set, so to re-apply undone changes you run a harmless command (e.g. `C-f`) then undo again. `undo-only` resumes undoing without ever redoing.
- **Why it matters:** This linear-history model is dramatically simpler than a branching undo tree — one stack, one "sequence-breaking" flag — and fits arena memory: no second tree to allocate. Adopt it exactly; encode the undo boundary ("last command was not undo") explicitly in the command loop.
- **Goal:** both
- **Applicability:** Direct

### Undo memory is explicitly bounded by configurable limits
- **Where:** p. 110 (§13.1 "Undo")
- **Insight:** Undo data is discarded during GC per three byte-limits: `undo-limit` (soft, 80000), `undo-strong-limit` (120000), `undo-outer-limit` (~12M, beyond which even the most recent change's undo is dropped with a warning). Buffers whose names start with a space keep no undo at all.
- **Why it matters:** The most directly transferable fact given arena/GC-limited memory: undo history must have a hard byte ceiling and discard-oldest-first. "Internal/scratch buffers keep no undo" maps to nEmacs's REPL echo / CIPHER scratch surfaces. Tie the discard pass to KEC's arena-reset boundaries the way Emacs ties it to GC.
- **Goal:** nEmacs
- **Applicability:** Direct

### Transpose commands fix the most common slip in one keystroke
- **Where:** pp. 110–111 (§13.2 "Transposing Text")
- **Insight:** `transpose-chars` (C-t), `transpose-words` (M-t), `transpose-sexps` (C-M-t), `transpose-lines` swap the two units around point; at end of line C-t swaps the last two chars; numeric arg 0 transposes the units ending at point and at mark.
- **Why it matters:** `transpose-chars` is the canonical fix for multi-tap fat-fingering and should be a first-class nEmacs command; `transpose-sexps` is exactly the structural edit kec-mode wants for swapping Lisp arguments (shares the balanced-expression scanner with paren editing).
- **Goal:** both
- **Applicability:** Direct

### Case-conversion commands don't move point (correct-and-continue)
- **Where:** p. 111 (§13.3 "Case Conversion")
- **Insight:** `M-l`/`M-u`/`M-c` lower/upper/capitalize; with a negative argument they convert the *last* word "without moving the cursor," so you fix a wrong-case word and keep typing.
- **Why it matters:** The principle — a correction that leaves point where you are so flow isn't broken — is right for nEmacs, where repositioning costs more (no mouse, coarse motion). Keep the in-place semantics but bind it to a layer gesture rather than the Meta-minus chord the device can't produce.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Cheap command repetition (`C-x z`, "ignore-value" args)
- **Where:** pp. 24–25 (§4.10–4.11)
- **Insight:** Three repetition mechanisms: a numeric arg as repeat count; `C-x z` (`repeat`) which re-runs the last command and continues on each extra `z`; and commands that care only *whether* an argument exists.
- **Why it matters:** One "repeat" key that extends any command without re-entering it saves keystrokes the 34-key layout can't spare. The "presence vs value of argument" convention fits KEC command signatures (an optional arg that's truthy-checked, matching KEC's `nil`-is-false model).
- **Goal:** nEmacs
- **Applicability:** Adapt

### A numbered single-key candidate loop is the right correction UI for a tiny screen
- **Where:** pp. 112–113 (§13.4 "Checking and Correcting Spelling")
- **Insight:** On a flagged word, Emacs shows numbered near-misses and waits for one keystroke: a digit picks a candidate; `r`/`R` replace; `a`/`A` accept; `SPC` skips; `q`/`C-g` abort.
- **Why it matters:** The *mechanism* — flag, present a short numbered list, accept one keystroke — is a near-perfect interaction grammar for nEmacs's amber 80×25 grid and 34-key input, and it generalizes to completion and REPL candidate selection. The actual spell *checker* (external Aspell/Ispell process) is out of scope.
- **Goal:** both
- **Applicability:** Adapt

## Chapters 5–7 — Minibuffer; M-x; Help (book pp. 26–44)

Emacs's three load-bearing UX primitives, all on the same reflective foundation: the **minibuffer** (a temporary editing surface that reuses the full editor to read arguments), **M-x** (name-based command invocation), and **Help** (self-documenting — possible only because commands are named Lisp functions carrying docstrings and keymaps are introspectable data).

### Minibuffer is the editor reused as a prompt surface
- **Where:** p. 26 (§5.1); p. 27 (§5.3)
- **Insight:** The minibuffer is an ordinary buffer ("albeit a peculiar one") shown in the echo area; all normal editing commands work inside it, only the prompt is read-only. It grows from one line to several when the argument is long.
- **Why it matters:** nEmacs already has an editor; the cheapest way to read commands/filenames/REPL input is to reuse that editing buffer in a reserved row rather than build a separate widget. One editor, two uses — minimal code, consistent keybindings.
- **Goal:** both
- **Applicability:** Direct

### Prompt + default argument convention
- **Where:** p. 26 (§5.1)
- **Insight:** Prompts end in a colon; a *default* in parentheses is used on bare RET. "Electric Default" hides the default once you type; `minibuffer-eldef-shorten-default` shows it compactly as `[default]`.
- **Why it matters:** On a multi-tap keyboard, a good default that RET accepts saves an entire slow text entry. The shorten-default option is precedent for nEmacs's tiny grid — show defaults compactly so a prompt still fits in 80 columns.
- **Goal:** both
- **Applicability:** Adapt

### Completion is a rebound-key subsystem inside the minibuffer
- **Where:** p. 28 (§5.4); p. 29 (§5.4.2)
- **Insight:** When completion is available, TAB/SPC/RET/`?` are *rebound* in the minibuffer: TAB completes as far as possible or lists; SPC completes one word / up to the next hyphen; `?` lists all; RET completes-then-submits. `a u TAB - f TAB` → `auto-fill-mode` in five keystrokes.
- **Why it matters:** The single biggest win for nEmacs — multi-tap entry is slow, so 2–3 chars + TAB is transformative. "Complete to next hyphen" fits Lisp's hyphenated names (`forward-char`, `cell-rows-usable`) perfectly. For kec-mode, the same mechanism drives `.lsp` symbol completion against the loaded environment.
- **Goal:** both
- **Applicability:** Direct

### Completion alternatives are data supplied by the requesting command
- **Where:** p. 28, p. 31 (§5.4.4)
- **Insight:** The candidate set comes from whichever command is reading the argument (command names, buffers, files); matching runs through ordered *completion styles* (`basic`, `partial-completion`, `initials`, …). `partial-completion` lets `em-l-m` → `emacs-lisp-mode`; `initials` matches `lch` → `list-command-history`.
- **Why it matters:** The candidate source is *data*, not hardcoded UI — KEC can expose "all bound symbols," "all defined functions," "all loaded cart names" as completion tables behind one reader. Partial/initials styles let abbreviated multi-tap input resolve long hyphenated names. Ship basic prefix first; partial-completion is a later upgrade.
- **Goal:** both
- **Applicability:** Adapt

### Completion exit has four strictness modes
- **Where:** p. 30 (§5.4.3)
- **Insight:** RET behavior depends on the argument's contract: *strict* (must match — M-x), *cautious* (requires a 2nd RET to confirm — files that must exist), *permissive* (anything), *permissive-with-confirmation* (asks `[Confirm]` if you RET right after a partial TAB).
- **Why it matters:** nEmacs's command reader should be strict (reject unknown commands) while REPL/search readers stay permissive — same machinery, parameterized by intent. The confirm-after-partial-TAB guards a real error a slow typist is *more* likely to hit.
- **Goal:** both
- **Applicability:** Adapt

### Minibuffer history with prefix/regexp recall
- **Where:** pp. 32–33 (§5.5)
- **Insight:** Each argument is saved to a per-category history list (files, buffers, commands, query args). `M-p`/`M-n` walk it; `M-r`/`M-s` jump to a matching entry; `history-length` caps it.
- **Why it matters:** History recall is the second-biggest multi-tap accelerator after completion — re-entering a long REPL form should cost one `M-p`, not a full re-type. KEC already persists per-deck REPL history, so this maps directly.
- **Goal:** both
- **Applicability:** Direct

### M-x: name-based invocation as the universal escape hatch
- **Where:** p. 36 (Ch. 6)
- **Insight:** "Most Emacs commands have no key bindings, so the only way to run them is by name." M-x reads a command name with completion, and reports the key binding afterward if one exists. M-x is itself just the command `execute-extended-command`.
- **Why it matters:** The core lesson for a 34-key device: you physically can't bind everything, so make *every* command reachable by name and let the long tail live behind M-x + completion. The echo-area key hint doubles as discovery.
- **Goal:** nEmacs
- **Applicability:** Direct

### Self-documentation flows from keys → named command → Lisp function
- **Where:** pp. 37–39 (§7.1–7.2)
- **Insight:** `describe-key` reports a key's command by *looking up the keymap*; `describe-function` shows a function's docstring ("since commands are Lisp functions, this works for commands too"); `where-is` inverts it. The whole help system is introspection over the data the editor runs on.
- **Why it matters:** The reflective payoff KEC is built to inherit: if nEmacs commands are named KEC functions and keymaps are KEC data, describe-key/function/where-is are a few introspection calls, not a separate docs subsystem. Attach docstrings to functions → help nearly for free.
- **Goal:** both
- **Applicability:** Direct

### Apropos: discovery by name/keyword/docstring, leaning on naming conventions
- **Where:** pp. 40–41 (§7.3)
- **Insight:** `apropos`/`apropos-command`/`apropos-documentation` search names and even docstrings for a word/regexp, listing matches with bindings. The manual lists the canonical verb/noun vocabulary (`char line word region buffer forward backward kill insert search goto…`) that makes apropos productive — discovery works *because* names follow conventions.
- **Why it matters:** A new user searches by intent ("kill", "forward") and finds the command + key. The prescriptive lesson: adopt a disciplined KEC naming vocabulary so apropos-style search finds things. kec-mode can offer apropos over the live KEC environment.
- **Goal:** both
- **Applicability:** Adapt

### Help buffers are navigable, cross-linked, stack-based (keyboard-only)
- **Where:** pp. 41–42 (§7.4)
- **Insight:** Help renders into a buffer where names are hyperlinks: RET follows, `help-go-back` retraces a history stack, TAB/`S-TAB` move between links. A scrollable help buffer surfaces a full docstring (vs the one-line echo area).
- **Why it matters:** nEmacs has no mouse, so the *keyboard* navigation model is the relevant one: TAB between links, RET to follow, a back-stack — all on a modifier layer. A scrollable help buffer is how to show a full docstring on 80×25.
- **Goal:** both
- **Applicability:** Adapt

### Fast vs slow confirmation (and password masking) — friction as safety
- **Where:** pp. 34–35 (§5.7–5.8)
- **Insight:** A single-keystroke `(y or n)` echo-area query is reserved for routine prompts; a heavier `(yes or no)` minibuffer query (type the full word) is reserved for consequential actions where a beat of attention matters. Passwords reuse a stripped minibuffer (no history/completion, chars echo as dots).
- **Why it matters:** The fast/slow split is deliberate friction-as-safety nEmacs should copy — cheap `y/n` for routine, full `yes/no` only where a wrong answer loses data (especially on a slow keyboard). Password mode shows the minibuffer is a *configurable* surface (history/completion/echo toggled per use) — one reader, many contracts.
- **Goal:** nEmacs
- **Applicability:** Adapt

## Chapters 8–10 — Mark & Region; Killing & Moving; Registers (book pp. 45–68)

The core editing **data model**: a region delimited by two pointers (point + mark) backed by a mark ring; a kill ring replacing a single OS clipboard with a navigable history; and registers, a general-purpose named-slot stash. The model is self-contained — it predates and outlives the GUI/clipboard — making it ideal for a clipboard-less, mouse-less device. The recurring structure is the bounded ring buffer plus a small keyed table.

### Point + mark are the whole selection model
- **Where:** p. 45 (§8.1)
- **Insight:** The region is simply the text between point and mark — no separate "selection object"; whichever is earlier is the start, and moving point continuously redefines it.
- **Why it matters:** Two integer offsets in `SystemState` — trivially cheap to represent in C, needs no mouse. The exact selection primitive nEmacs should reproduce; kec-mode inherits it from host Emacs.
- **Goal:** both
- **Applicability:** Direct

### Activation vs. existence — the active-mark distinction
- **Where:** p. 45, p. 50 (§8.7)
- **Insight:** Transient Mark mode separates two concepts: the mark always exists (defining a region), but is "active" only transiently — text changes and `C-g` deactivate it, which controls highlighting and which commands act on the region.
- **Why it matters:** nEmacs needs one boolean (`mark_active`) over the always-present mark; on an amber grid with no OS selection affordance, highlight-on-active is the only feedback that a region is live. The default (transient on/off) shapes how destructive region commands feel.
- **Goal:** both
- **Applicability:** Direct

### The mark ring as a position-history ring buffer
- **Where:** p. 48 (§8.4); p. 49 (§8.5)
- **Insight:** Each buffer keeps a ring of former mark positions (`mark-ring-max` 16); setting a mark pushes the old one; `C-u C-SPC` walks point back through them, discarding the oldest when full. A separate global mark ring records cross-buffer jumps.
- **Why it matters:** A fixed-capacity ring of integer offsets is the cheapest "navigation history" — perfect for arena-bounded nEmacs (a static array of N offsets, deterministic memory, no allocation). Gives a tiny device a real "jump back to where I was."
- **Goal:** nEmacs
- **Applicability:** Direct

### Mark-and-object commands give structural selection from the keyboard
- **Where:** p. 47 (§8.2)
- **Insight:** `mark-word`, `mark-sexp`, `mark-paragraph`, `mark-defun`, `mark-whole-buffer` set point and mark around a syntactic unit without a mouse; repeating extends by one more unit.
- **Why it matters:** With no mouse, keyboard structural selection is how nEmacs selects anything larger than a char — and `mark-sexp` (grab a balanced expression, extend outward) is especially valuable for both nEmacs and kec-mode.
- **Goal:** both
- **Applicability:** Direct

### Kill vs. delete — two erasure verbs, one recoverable
- **Where:** p. 52 (§9.1)
- **Insight:** *kill* commands erase **and** save to the kill ring; *delete* commands erase without saving. Single chars and pure whitespace are deleted; nontrivial spans are killed, so killing is "a very safe operation."
- **Why it matters:** This naming-as-contract convention should govern nEmacs's command set — on a device with limited undo depth, "anything substantial I erase is recoverable from the ring" is a big safety win. kec-mode users already expect it.
- **Goal:** both
- **Applicability:** Direct

### The kill ring is a clipboard-history ring, not a clipboard
- **Where:** p. 55 (§9.2.1–9.2.2)
- **Insight:** A single shared list of recently killed blocks (`kill-ring-max` 60); a new kill pushes to the front, oldest drops when full. `C-y` yanks the front; `M-y` (yank-pop), valid only right after a yank, moves a "last yank" pointer around the ring and swaps the buffer text to match — the ring order never changes.
- **Why it matters:** The headline lesson for a device with **no OS clipboard**: a bounded ring of N text blocks + a "last-yank" index gives cut/copy/paste *with history* entirely in-memory. Size the ring to the arena budget (well below 60); multi-item paste a single clipboard could never offer.
- **Goal:** nEmacs
- **Applicability:** Direct

### Yank sets the mark; yank-pop is a stateful follow-on command
- **Where:** pp. 55–56 (§9.2)
- **Insight:** `C-y` leaves point after the inserted text and sets the mark at its start (so the yank is a ready-made region); `M-y` is only meaningful when "the previous command was a yank," requiring the runtime to track the last command.
- **Why it matters:** nEmacs's input dispatch must track "what was the last command" to gate `yank-pop` — a concrete command-loop requirement, and a reminder that some commands are context-polymorphic on history (echoing ADR-0016). Yank-sets-mark gives free "select what I just pasted."
- **Goal:** nEmacs
- **Applicability:** Direct

### Appending kills — consecutive kills coalesce into one entry
- **Where:** p. 56 (§9.2.3)
- **Insight:** Two+ kill commands in a row merge into a single ring entry (forward kills append, backward kills prepend), so one `C-y` retrieves the whole accumulation; `append-next-kill` forces a join across intervening commands. Requires a "last command was a kill" flag.
- **Why it matters:** Accumulating scattered fragments into one yankable block costs only a flag + string concat into the front slot — cheap for nEmacs, expected by kec-mode authors.
- **Goal:** both
- **Applicability:** Direct

### Rectangles — a second region interpretation over the same point/mark
- **Where:** pp. 60–61 (§9.5)
- **Insight:** The same point/mark pair can be read as a *rectangle* (columns × lines) with its own kill slot (the "last killed rectangle," **not** the kill ring); `C-x r k/d/y` and `rectangle-mark-mode`.
- **Why it matters:** On a fixed character grid, columnar text (ASCII tables, box-drawing, status rows) is common and rectangle editing is the natural tool — but a clear second-tier feature (separate single-slot store + column logic), worth adapting only after the linear kill ring lands.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Registers — named single-char slots as a general-purpose stash
- **Where:** pp. 64–65 (§10.1–10.2)
- **Insight:** A register named by one character holds exactly one thing — a position, text, rectangle, number, window config, or filename. `C-x r SPC`/`C-x r j` save/jump a position; `C-x r s`/`C-x r i` save/insert text.
- **Why it matters:** A tiny keyed table (char → tagged union) delivering outsized power per byte — the "cheap power feature" profile a constrained device wants. Single-char naming maps onto the keyboard; the tagged-union value is a natural C representation.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Mouse, clipboard, primary/secondary selection, CUA — the GUI layer to drop
- **Where:** pp. 57–59 (§9.3), p. 62 (§9.6)
- **Insight:** Much of these chapters covers GUI integration — system-clipboard sync on kill/yank, X primary/secondary selection, CUA `C-x/C-c/C-v` — all layered *on top of* the kill ring, never replacing it.
- **Why it matters:** nEmacs has no mouse and no OS clipboard, so every clipboard-sync / selection / drag / CUA binding is out of scope — confirming the kill ring must be the **complete** transfer mechanism, not a cache in front of a clipboard. (kec-mode in desktop Emacs gets all this free; don't reimplement.)
- **Goal:** nEmacs
- **Applicability:** Avoid

## Chapter 11 — Controlling the Display (book pp. 69–89)

How Emacs shows a slice of a too-large buffer (scrolling, recentering), deliberately restricts what's visible (narrowing, selective display, View mode), and the abstraction stack for *how* text looks — faces, font-lock, mode line as data. The recurring lesson for a tiny monochrome grid: separate *meaning* ("this is a comment") from *rendering* ("draw it dim"), and the cheap focus mechanisms matter far more at 80×25 than on a big screen.

### Recentering as a policy knob, not a fixed behavior
- **Where:** p. 70 (§11.2)
- **Insight:** `recenter-top-bottom` (C-l) cycles point through center/top/bottom; the cycle order is a customizable `recenter-positions` list.
- **Why it matters:** On 80×25, "show me context around point" is a primary affordance; exposing the recenter target as a small data list (not hardcoded) lets the device reserve rows for the firmware status/action bars without rewriting render logic.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Pick exactly one automatic-scroll policy (conservative = fewest repaints)
- **Where:** pp. 71–72 (§11.3)
- **Insight:** Three conflicting variables control scroll-on-point-offscreen; the manual says pick *one*. `scroll-conservatively > 100` = "scroll the minimum to reveal point, never recenter."
- **Why it matters:** Minimal-scroll repaints the fewest cells, suiting nEmacs's event-driven ~20fps redraw and arena render budget; full recenter-on-every-edge-cross would needlessly repaint the whole grid.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Scroll margins keep point off the dangerous edges
- **Where:** pp. 70, 72 (§11.2–11.3)
- **Insight:** `scroll-margin` keeps ≥N lines between point and the window edge; the viewport leads the cursor instead of trapping it at the boundary.
- **Why it matters:** On 25 rows a 2–3 row margin preserves vertical context so the operator never edits on the literal last visible line — a cheap comparison in the scroll-decision step, no extra rendering cost.
- **Goal:** nEmacs
- **Applicability:** Direct

### Horizontal scrolling + truncation is the answer to a narrow screen
- **Where:** p. 72 (§11.4)
- **Insight:** With truncation (not wrapping), Emacs auto-scrolls sideways to keep point visible; the cursor pins to the edge on text terminals when point is off-screen.
- **Why it matters:** 80 columns is brutally narrow for `.lsp`; horizontal scroll + truncation is the realistic nEmacs display mode. The "cursor vanishes off-edge" behavior is a concrete bug to avoid — pin the cursor at the column edge like a text terminal.
- **Goal:** nEmacs
- **Applicability:** Direct

### Narrowing — the cheapest focus mechanism for a tiny screen
- **Where:** p. 73 (§11.5)
- **Insight:** Narrowing restricts the accessible portion of the buffer (to region/page/defun); everything outside becomes invisible and immovable but preserved. `widen` restores it; `Narrow` shows in the mode line.
- **Why it matters:** The single highest-value display transfer for nEmacs: narrowing to the current defun turns "scroll a 400-line file" into "the whole screen is the one function," with motion naturally bounded — costs only a start/end restriction pair, no extra memory.
- **Goal:** nEmacs
- **Applicability:** Direct

### Narrowing ships *disabled* because it confuses — gate powerful focus modes
- **Where:** p. 73 (§11.5)
- **Insight:** `narrow-to-region` ships as a disabled command (prompts for confirmation) because a narrowed buffer looks like data loss to the uninitiated.
- **Why it matters:** nEmacs has no manual at hand; "the rest of my file vanished" is alarming on a single-foreground display. Make the narrowed state unmistakable (mode-line `Narrow` marker) and/or require a deliberate gesture so the operator never gets stuck.
- **Goal:** nEmacs
- **Applicability:** Adapt

### View mode — read-only sequential scanning
- **Where:** p. 73 (§11.6)
- **Insight:** A minor mode for scanning by screenfuls without risk of editing: SPC forward, DEL back, `s` search, `q` quit to prior position.
- **Why it matters:** Maps perfectly to reviewing REPL output, help text, or cart source on nEmacs where accidental hardware keystrokes are easy; the SPC/DEL screenful model needs no cursor management and minimal redraw.
- **Goal:** nEmacs
- **Applicability:** Direct

### Faces are an abstraction between meaning and rendering
- **Where:** pp. 74–78 (§11.8, §11.10)
- **Insight:** A *face* is a named bundle of display attributes (font, weight, fg/bg, underline). Modes assign faces by *meaning* ("this is a string"); a face renders differently per frame, and Emacs already maps faces down to what a text terminal can do.
- **Why it matters:** The key conceptual transfer for nEmacs's monochrome amber display: keep the meaning→face indirection, but resolve face→pixels to the few attributes an 8×8 single-foreground cell can express (dim, reverse, underline, blink — **not** color). Cart/mode code names a face; the renderer owns the monochrome lowering. Same architecture, different attribute set.
- **Goal:** both
- **Applicability:** Adapt

### Monochrome fallback is intensity/inverse — and bold+inverse can be illegible
- **Where:** pp. 74, 77, 89 (§11.8, §11.23)
- **Insight:** On non-windowed terminals `mode-line` renders as inverse of default; the manual warns **bold + inverse video together are hard to read** (`tty-suppress-bold-inverse-default-colors`).
- **Why it matters:** Direct guidance for nEmacs's attribute palette: reverse video is the workhorse for the status/action bars on a single-foreground amber grid, but stacking bright+reverse on an 8×8 phosphor cell risks the exact illegibility Emacs warns about — budget attributes so emphasis layers don't collide.
- **Goal:** nEmacs
- **Applicability:** Direct

### Font-lock — rule-driven fontification supplied by the major mode
- **Where:** pp. 78–79 (§11.12)
- **Insight:** Font Lock is a buffer-local minor mode where each *major mode* supplies the rules (comments/strings/keywords/functions); `font-lock-add-keywords` adds regexp→face patterns; `font-lock-maximum-decoration` tiers how much highlighting is applied.
- **Why it matters:** The direct blueprint for desktop kec-mode: a font-lock keyword table mapping KEC syntax (`set`, `mac`, `fn`, `:keywords`, `nil`, parens) to standard `font-lock-*` faces. The decoration tiers also model an nEmacs "minimal highlight" level for a constrained renderer.
- **Goal:** kec-mode
- **Applicability:** Direct

### The leftmost-column-paren convention is a bounded-parse speed hack
- **Where:** p. 79 (§11.12)
- **Insight:** Lisp mode assumes an open delimiter in column 0 always starts a defun, so it finds a known-safe parse start without rescanning from buffer top. Consequence: a `(` in column 0 *inside a string/comment* breaks fontification (escape it `\(`).
- **Why it matters:** Both projects parse `.lsp`. For nEmacs it's the more important lesson — on a GC-stack-limited, arena-bounded device you *want* a bounded, convention-based parse start so fontifying a screen never rescans from the buffer head. Adopt the column-0 convention deliberately.
- **Goal:** both
- **Applicability:** Adapt

### JIT fontification — only style what's on screen
- **Where:** p. 80 (§11.12)
- **Insight:** Emacs fontifies only the visible portion on visit and lazily fontifies regions as they scroll into view (JIT Lock), finishing during idle.
- **Why it matters:** The performance model nEmacs must copy: with ~20fps redraw and arena bounds, only the ~2000 currently-visible cells should ever be tokenized/styled per frame; never fontify the whole buffer. Scroll triggers incremental fontification; idle mops up.
- **Goal:** nEmacs
- **Applicability:** Direct

### Mode line as composable, self-throttling status data
- **Where:** pp. 84–85 (§11.18)
- **Insight:** The mode line is independently toggleable fields (`pos`, size-indication, `line-number-mode`, `column-number-mode`, time/battery). Line-number display is *suppressed* past `line-number-display-limit` because computing it on huge buffers is too slow.
- **Why it matters:** nEmacs's Row 0 / Row 74 bars are exactly this — a composable field set in a fixed row. The self-throttling lesson is gold: drop expensive fields (line numbers) when the buffer is large rather than stalling redraw, which matters acutely on the device's budget.
- **Goal:** nEmacs
- **Applicability:** Direct

### Selective display / truncation as cheap overview tools
- **Where:** pp. 83–84, 87 (§11.17, §11.21)
- **Insight:** `set-selective-display N` hides lines indented ≥ N columns, marking collapses with `...` — an instant indentation outline. Truncation clips long lines (with `$`/fringe markers) instead of wrapping.
- **Why it matters:** On 80×25, selective display gives a free structural overview of a nested `.lsp` file with no folding UI, and truncation (with a column-edge `$` marker, since nEmacs has no graphical fringe) keeps one logical line to one screen row so the cell renderer stays predictable.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Cursor and control-character display are explicit, terminal-aware rules
- **Where:** pp. 85–87 (§11.19–11.20)
- **Insight:** Control chars render as caret (`^A`) or octal (`\230`) via `escape-glyph`; tab expands to the next `tab-width` stop; cursor shape (`cursor-type`) and blink are explicit settings; on text terminals the terminal owns part of cursor appearance.
- **Why it matters:** nEmacs *is* the terminal, so it owns every rule: how to draw tabs/control bytes in 8×8 cells, a cursor glyph that reads on amber (a reverse-video block ≈ box cursor), and bounding/disabling blink to respect the event-driven redraw budget rather than waking the renderer on a timer.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Visual-line (word-wrap) vs raw continuation is a per-buffer policy
- **Where:** pp. 87–88 (§11.21–11.22)
- **Insight:** Default continuation splits long lines mid-word; Visual Line mode wraps at word boundaries and rebinds `C-a`/`C-e`/`C-k` to screen lines.
- **Why it matters:** For prose-ish content (REPL output, help, CIPHER text) word-wrap is more legible on the narrow grid; for `.lsp`, truncation is usually better. Offer *both* and let movement commands optionally bind to screen-line vs logical-line semantics — a per-buffer policy, not a global law.
- **Goal:** nEmacs
- **Applicability:** Adapt

## Chapters 12 & 14 — Searching & Replacement; Keyboard Macros (book pp. 90–108, 114–121)

Incremental search (search-as-you-type), word/symbol/regexp variants, and the interactive `query-replace` loop; then keyboard macros — recording a command stream and replaying it. Both are possible because every action is a named command on one uniform input→command pipeline. Several Ch 12 features (the full regexp engine, multi-buffer occur) are heavyweight for an arena-bounded device and should be scoped down.

### Isearch state machine: type-to-search, point lands at the match
- **Where:** p. 90 (§12.1.1)
- **Insight:** Search begins on the first character typed, advancing point past each match as the string grows; `DEL` peels the last char, `RET` exits at the match, and any non-special command exits *and is then executed*.
- **Why it matters:** The landmark interaction to clone — "exit-leaves-point, stray-command-exits-and-runs" is cheap and removes the need for a separate search dialog on a tiny screen. kec-mode inherits it free.
- **Goal:** both
- **Applicability:** Direct

### The full isearch event loop (repeat / wrap / overwrap / fail)
- **Where:** pp. 91–92 (§12.1.2–12.1.3)
- **Insight:** `C-s` repeats forward, `C-r` flips direction keeping the string; a failed repeat wraps to start (`Wrapped`, then `Overwrapped`); an unfound string shows `Failing I-Search`; the first `C-g` strips unfound chars (keeping the matched prefix), a second aborts to the start point.
- **Why it matters:** The precise state machine nEmacs must encode: `{ direction, string, match-pos, wrapped?, failing? }` + two-stage `C-g`. Capturing wrap/overwrap and "C-g strips then aborts" avoids reinventing a worse search UX.
- **Goal:** nEmacs
- **Applicability:** Direct

### Yank-into-search builds the query from buffer text
- **Where:** p. 93 (§12.1.5)
- **Insight:** Inside isearch, `C-w` appends the next word at point, `M-s C-e` to end of line, `C-y` the kill — grow the search from surrounding text instead of typing it.
- **Why it matters:** On a multi-tap device, "search for the symbol under point" is a few keystrokes vs a slow type-out — a huge ergonomics win. For kec-mode, `C-w` yank-word searches the identifier you're sitting on. Pick a small subset of yank verbs that fit the layer budget.
- **Goal:** both
- **Applicability:** Adapt

### "Any non-search key exits and runs" is a dividend of the command pipeline
- **Where:** p. 90 (§12.1.1)
- **Insight:** Isearch special-cases a short key list; everything else falls through to the normal dispatcher, which exits search *and* executes the command in one stroke.
- **Why it matters:** Works only because input flows through one uniform key→command lookup with a transient isearch keymap on top. nEmacs should model isearch as a temporary keymap/minor-mode on the same dispatch path (mirrors ADR-0016), not a bespoke modal loop — fewer special cases, stray keys "just work."
- **Goal:** nEmacs
- **Applicability:** Direct

### Word and symbol search honor token boundaries
- **Where:** pp. 95–96 (§12.3–12.4)
- **Insight:** Word search matches a word sequence regardless of intervening punctuation; symbol search additionally requires symbol-boundary alignment, so `forward-word` won't match inside `isearch-forward-word`.
- **Why it matters:** Symbol search is directly relevant to kec-mode (jump between exact uses of a `.lsp` identifier). For nEmacs, lightweight symbol-boundary search via a char-class table gives precise navigation cheaply — skip the full `\_<`/`\_>` regexp machinery on-device.
- **Goal:** both
- **Applicability:** Adapt

### Regexp search is the expensive tier — scope it for the device
- **Where:** pp. 96–102 (§12.5–12.8)
- **Insight:** The regexp engine carries backtracking, greedy/non-greedy operators, nine numbered capture groups with full backtracking across alternations, backreferences, and syntax/category classes — a substantial matcher with a match-data store.
- **Why it matters:** A backtracking engine with capture state is real heap/stack pressure — what an arena-bounded, GC-stack-limited runtime (`GCSTACKSIZE` 256) can't casually afford. nEmacs should ship literal + word + symbol search and defer regexp, or offer a bounded subset (anchors + char classes + `*`/`+`/`?`, no backrefs). kec-mode gets full regexp free from host Emacs.
- **Goal:** both
- **Applicability:** Adapt (nEmacs: bounded subset or omit) / Direct (kec-mode)

### Case-fold and lax-space are search-string-driven, not modal flags
- **Where:** pp. 92, 102 (§12.1.4, §12.9)
- **Insight:** A space matches any whitespace run by default; case sensitivity is *inferred from the query* — all-lowercase searches case-insensitively, any uppercase makes it case-sensitive.
- **Why it matters:** Inferring case from the typed string removes a settings toggle from a device with almost no UI room — intent is expressed through what you type. A clean low-state behavior nEmacs can adopt verbatim.
- **Goal:** both
- **Applicability:** Direct

### Query-replace: the interactive per-match replace loop
- **Where:** pp. 105–106 (§12.10.4)
- **Insight:** `M-%` walks matches one at a time, highlighting the current and reading one action key: `SPC`/`y` replace, `n` skip, `.` replace-and-exit, `!` replace-all, `^` back up, `,` replace-and-pause, `q` quit; any unbound key exits and is reread as a command.
- **Why it matters:** A single-key decision loop is ideal for a few-key device: no dialog, one keystroke per match, `!` to bulk-finish. nEmacs should mirror the action-key vocabulary (`y`/`n`/`!`/`q`/`^`) on a transient keymap. `^` back-up and `,` pause need a small per-match stack — bound the depth.
- **Goal:** both
- **Applicability:** Adapt

### Keyboard macros are record-and-replay of the command stream
- **Where:** pp. 114–115 (§14.1)
- **Insight:** `F3` starts recording; subsequent keystrokes both execute *and* append to the macro (you watch the effect as you define it); `F4` ends/replays; a numeric prefix replays N times (0 = until error). Minibuffer arguments become part of the macro, so replay reuses them.
- **Why it matters:** The headline power feature a tiny keyboard makes *more* valuable — automate a repetitive edit once, replay across a file. Feasible only because the system records the uniform input→command stream. Expose record/replay early; it multiplies the value of every other command.
- **Goal:** nEmacs
- **Applicability:** Direct

### Macros work only because every action is a named command on one pipeline
- **Where:** p. 114 (§14.1)
- **Insight:** A macro *is* the recorded command sequence; replay re-runs it through the same dispatcher. The manual contrasts this with Lisp: the macro "language" is the command stream itself — simple to capture, but for logic you drop to Lisp.
- **Why it matters:** The architectural payoff of "everything is a named command bound via keymaps" — exactly the model KEC already has. nEmacs gets macros nearly free if input dispatch records the command stream; it also draws the boundary: macros for repetition, drop to KEC Lisp for conditional/general logic.
- **Goal:** both
- **Applicability:** Aspirational (nEmacs) / Direct (kec-mode inherits host macros)

### Macro ring, counter, and query give parameterized replay
- **Where:** pp. 115–118 (§14.2–14.4)
- **Insight:** Defined macros stack on a ring; each has an auto-incrementing counter you insert (for numbered output); `C-x q` inserts a query-replace-style pause so replay asks yes/skip/quit each iteration.
- **Why it matters:** Counter + per-iteration query turn a dumb replay into a supervised, parameterized one — wanted when batch-editing on a device where you can't eyeball a whole buffer. Second-wave layers on top of basic record/replay; the ring's multi-slot storage has a bounded memory cost.
- **Goal:** nEmacs
- **Applicability:** Aspirational

### Naming/saving a macro promotes it to a first-class command
- **Where:** pp. 118–120 (§14.5–14.7)
- **Insight:** `C-x C-k n` names the last macro (the name becomes a real `M-x`-callable command), `C-x C-k b` binds it to a key, and `insert-kbd-macro` writes it out as Lisp to save in an init file.
- **Why it matters:** A named macro is indistinguishable from a built-in — the uniform model again. For nEmacs, per-deck persisted macros (like per-deck REPL history) become reusable named commands; "insert as Lisp code" maps onto KEC Lisp and is how kec-mode users would persist a macro. Skip full stepwise-edit UX initially.
- **Goal:** both
- **Applicability:** Adapt (nEmacs) / Direct (kec-mode)

## Chapters 16–17, 20–21 — Buffers; Windows; Modes; Indentation (book pp. 147–161, 199–207)

The structural architecture of an Emacs: the **buffer** (editable object + its own point + major mode + local-variable bag), the **window** (a viewport decoupled many-to-many from buffers), the **mode** (major = one personality, minor = composable layers, both named `-mode` commands with hooks), and **mode-driven indentation** (TAB delegates to the major mode). The architectural payoff: almost everything is a buffer-local variable set by the active modes, and modes are named Lisp functions — which maps cleanly onto a Fe/KEC userland.

### The buffer is the unit of organization
- **Where:** p. 147 (§16 intro)
- **Insight:** A buffer holds text plus per-buffer state — visited file, modified flag, its own major + minor modes, and buffer-local variable values. Exactly one buffer is current; commands operate on it.
- **Why it matters:** nEmacs should adopt the buffer as its core struct (text + point + major mode + local-var bag), not one global text field. This is what lets a `.lsp` edit buffer and the REPL coexist as siblings with independent state.
- **Goal:** both
- **Applicability:** Direct

### Buffer-local variables are the customization substrate
- **Where:** p. 147 (§16 intro); p. 423 (§33.2.3)
- **Insight:** Per-buffer state (mode, read-only flag, indent settings) is stored as buffer-local variables — ordinary variables holding a different value per buffer.
- **Why it matters:** Implement one buffer-local-variable mechanism in the Fe userland and modes, read-only, and indentation fall out of it rather than each being special-cased. A fixed-size local-var alist per buffer keeps memory deterministic.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Read-only is a buffer-local flag, used for generated views
- **Where:** p. 149 (§16.3)
- **Insight:** A buffer can be read-only (`buffer-read-only`, `C-x C-q` toggles); subsystems present generated content in read-only buffers responding only to special single-key commands.
- **Why it matters:** nEmacs's REPL transcript, a help view, or a mission-board listing can each be a read-only buffer with its own command set — reusing the buffer abstraction for non-editable panes instead of inventing a separate "screen" concept.
- **Goal:** nEmacs
- **Applicability:** Adapt

### A window is a viewport; buffer and view are decoupled
- **Where:** p. 156 (§17.1)
- **Insight:** Each window shows one buffer, but a buffer may appear in several windows, each keeping its *own* point (independent scroll). One window is selected; its buffer is current. Mark is shared per-buffer.
- **Why it matters:** Even if nEmacs only shows 1–2 panes, modeling point as a property of the *view* (not the buffer) is the clean way to show the editor and REPL on the same buffer, or split source-above/REPL-below. Capture it now to avoid a rewrite if a second pane is added.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Splits are vertical/horizontal halvings with minimum sizes
- **Where:** pp. 156–157, 159 (§17.2, §17.5)
- **Insight:** `C-x 2`/`C-x 3` split; `C-x 0`/`C-x 1` delete; windows enforce minimums (`window-min-height` 4, `window-min-width` 10) and auto-truncate when narrower than ~50 cols.
- **Why it matters:** On 80×25 / 128×75, vertical real estate is scarce — a horizontal split (REPL under source) is the realistic nEmacs layout, with a hard minimum-rows rule + truncation-when-narrow. Side-by-side splits are likely too cramped.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Major mode = a buffer's single, exclusive personality
- **Where:** p. 199 (§20.1)
- **Insight:** Every buffer has exactly one major mode determining keymap, indentation, syntax, comment delimiters; major modes are mutually exclusive. The mode name maps to a command (`M-x lisp-mode`) and to buffer-local `major-mode`; Fundamental mode is the do-nothing default.
- **Why it matters:** The core extensibility decision: nEmacs gets a `kec-lisp-mode` (the `.lsp` personality) and a separate `repl-mode`, each owning its keymap + TAB/indent; desktop kec-mode is literally an Emacs major mode. One-major-mode-per-buffer keeps dispatch simple and bounded.
- **Goal:** both
- **Applicability:** Direct

### Minor modes are independent, composable, toggleable layers
- **Where:** pp. 200–201 (§20.2)
- **Insight:** Minor modes layer optional features on top of the major mode; any number active at once, independent of each other; most buffer-local. Each has a `-mode` command that toggles (no arg) or force-sets (prefix arg), and a paired variable non-nil when enabled.
- **Why it matters:** nEmacs feature layers — paren-match, auto-indent, a CIPHER-overlay indicator, multi-tap overwrite — should be minor modes toggled per buffer, not baked into the major mode. The toggle/force-arg convention is a tiny uniform contract worth copying verbatim into the KEC command layer.
- **Goal:** both
- **Applicability:** Direct

### Mode hooks: the user-extension seam at activation
- **Where:** p. 200 (§20.1)
- **Insight:** Every major mode runs a named *mode hook* (a function list) each time it's enabled (`lisp-mode-hook`); hooks compose hierarchically (`prog-mode-hook` before specific ones) and are the idiomatic way to enable minor modes per mode.
- **Why it matters:** Hooks are the extensibility skeleton — they let KEC users and cart authors add behavior at mode activation without patching the mode. nEmacs should fire a `<mode>-hook` on every mode entry; kec-mode users will expect `kec-lisp-mode-hook`.
- **Goal:** both
- **Applicability:** Direct

### Mode commands are named Lisp functions, not hardwired flags
- **Where:** pp. 199–201 (§20.1–20.2)
- **Insight:** Modes are entered by calling `foo-mode` commands; `major-mode` and each minor-mode variable are ordinary Lisp values. The whole mode machinery is "just functions and variables" reachable from Lisp and bindable to keys.
- **Why it matters:** A perfect fit for the KEC ecosystem (commands = named Lisp functions): modes become Fe functions registered through the FFI seam, so a cart or user could define a new nEmacs mode in KEC Lisp. Reinforces "everything is a named command" as the nEmacs design law.
- **Goal:** both
- **Applicability:** Direct

### Mode selection is an ordered fallback chain (auto-mode-alist & friends)
- **Where:** pp. 202–204 (§20.3)
- **Insight:** On visiting a file the major mode is chosen by precedence: file-local `-*-Mode-*-` → `#!` line → `magic-mode-alist` (content) → `auto-mode-alist` (filename regexp, `"\\.c\\'" . c-mode`) → `magic-fallback-mode-alist`. `normal-mode` re-runs it.
- **Why it matters:** kec-mode registers by adding `("\\.lsp\\'" . kec-lisp-mode)` to `auto-mode-alist` — the standard hook. nEmacs can use a stripped extension→mode step, but keep the file-local mode line so a `.lsp` cart can pin its own mode.
- **Goal:** both
- **Applicability:** Direct (kec-mode) / Adapt (nEmacs)

### Indentation is mode-driven: TAB delegates to the major mode
- **Where:** p. 205 (§21.1)
- **Insight:** TAB runs `indent-for-tab-command`, dispatching to the major mode's indent function — next tab stop in text modes, *correct* indentation computed from preceding lines in programming modes. Same key, mode-dependent behavior.
- **Why it matters:** kec-mode's whole indentation value is a Lisp-aware indent function on TAB (align to the enclosing form). nEmacs's `kec-lisp-mode` needs the same: TAB computes sexp indentation, not a literal tab. The single most important kec-mode feature after font-lock; indentation logic lives in the mode, not the keypress handler.
- **Goal:** both
- **Applicability:** Direct

### Tabs-vs-spaces is a buffer-local policy; prefer spaces
- **Where:** pp. 206–207 (§21.2–21.3)
- **Insight:** `indent-tabs-mode` (buffer-local) chooses tab chars vs spaces; nil forces spaces. Tab stops default to every 8 columns; display `tab-width` is independent of indentation policy.
- **Why it matters:** kec-mode should set `indent-tabs-mode` nil so `.lsp` indents with spaces (consistent everywhere, no tab-width surprises). For nEmacs on a fixed-cell grid, spaces-only is simpler and safer — no reason to emit tabs into cart source.
- **Goal:** both
- **Applicability:** Direct

### Auto-indent-on-newline is a toggleable minor mode
- **Where:** p. 207 (§21.4)
- **Insight:** Electric Indent mode auto-indents the new line after every RET (global `electric-indent-mode` + per-buffer variant); `tab-always-indent` tunes whether TAB indents/completes/inserts.
- **Why it matters:** For nEmacs's constrained 34-key + multi-tap input, auto-indent-on-RET sharply cuts keystrokes entering Lisp. Make it a minor mode (toggleable) reusing the same indent function TAB calls.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Explicit buffer lifecycle is mandatory under bounded memory
- **Where:** pp. 149–152 (§16.4–16.5)
- **Insight:** Buffers are explicitly created, switched (`C-x b`), listed, and *killed* (`kill-buffer`, with `kill-buffer-hook`) to release memory. Indirect buffers (§16.6) share base text but keep independent point/mode — a niche feature.
- **Why it matters:** nEmacs needs an explicit create/switch/kill lifecycle with a kill hook, because arena memory is bounded — killing buffers to reclaim arena space is a hard requirement. Indirect buffers, the full Buffer-Menu UI, and frames are out of scope for v0.x.
- **Goal:** nEmacs
- **Applicability:** Adapt (lifecycle) / Avoid (indirect buffers, Buffer Menu, frames)

## Chapters 23–24 — Editing Programs; Evaluating Lisp (book pp. 240–260, 276–280)

Emacs treats every programming major mode as four syntax-driven services — defun motion, structural indentation, balanced-paren editing, comment handling — all from one syntax table, with font-lock/completion/folding layered on. For Lisp, "defun" = the top-level form, indentation is computed from sexp nesting, and `C-M-`-prefixed commands move/kill by balanced expression. The eval surface (24.7–24.11) distinguishes editing modes, an in-buffer eval-print REPL, and a true inferior-process REPL via comint — and the "eval in my own image" vs "ship to an external process" fork is the central architectural decision for wiring `kec`.

### A programming mode is a syntax bundle, not a feature list
- **Where:** p. 240 (§23.1)
- **Insight:** A language mode "specifies the syntax of expressions, the customary rules for indentation, how to do syntax highlighting, and how to find the beginning or end of a function definition." Entering it runs `prog-mode-hook` then `<lang>-mode-hook`.
- **Why it matters:** The build manifest for kec-mode: derive from `prog-mode`, supply a syntax table, indentation function, font-lock keywords, defun delimiters, and a `kec-mode-hook`. nEmacs's "structural editor" is the same four services minus highlighting.
- **Goal:** both
- **Applicability:** Direct

### The defun = a top-level form; provide three motion verbs
- **Where:** pp. 241–242 (§23.2.2)
- **Insight:** `beginning-of-defun` (`C-M-a`), `end-of-defun` (`C-M-e`), `mark-defun` (`C-M-h`) move over / select the current top-level definition; repetition and args walk between defuns.
- **Why it matters:** For KEC a defun is a top-level `(...)`. These three verbs are the backbone of "operate on the form I'm in" — kec-mode gets them free from `prog-mode`; nEmacs should bind equivalents since structural selection of a whole top-level form is the primitive for eval-defun and cut/move.
- **Goal:** both
- **Applicability:** Direct

### The column-0 open-paren convention buys cheap defun-finding
- **Where:** p. 241 (§23.2.1)
- **Insight:** Modes assume an opening delimiter at the left margin starts a defun, so they never rescan to buffer start. A `(` at column 0 inside a string must be escaped (`\(`).
- **Why it matters:** A performance hack worth copying: nEmacs is arena-bounded and can't afford full-buffer rescans per motion/indent. Adopt "column-0 paren = defun start" (with the escaped-paren caveat) so defun motion is O(local), not O(buffer).
- **Goal:** nEmacs
- **Applicability:** Adapt

### Lisp indentation is computed from sexp nesting, not stored
- **Where:** pp. 243–244 (§23.3.1, §23.3.3)
- **Insight:** TAB reindents the current line from "the indentation and syntactic content of the preceding lines." Standard rule: align under the first argument if it's on the start line, else under the function name; later lines align at the same nesting depth.
- **Why it matters:** The heart of kec-mode's indenter and nEmacs's auto-indent — indentation is *derived from paren structure on demand*, never persisted. Ideal for arena-bounded nEmacs: no stored layout, just recompute from the open-paren stack on TAB/newline.
- **Goal:** both
- **Applicability:** Direct

### Per-symbol indentation overrides ("def" forms, `lisp-indent-function`)
- **Where:** pp. 244–245 (§23.3.3)
- **Insight:** Names starting with `def` treat their second line as a *body* (indented `lisp-body-indent`); arbitrary per-symbol patterns come from the `lisp-indent-function` property; `lisp-indent-offset` forces a global override.
- **Why it matters:** KEC has special forms (`mac`, `let`, quasiquote, `def`-family) wanting body-style indent rather than arg-alignment. kec-mode needs a symbol→indent-rule table; nEmacs can ship a tiny hardcoded list of body-indenting heads (`def*`, `let`, `mac`, `fn`).
- **Goal:** both
- **Applicability:** Adapt

### Reindent a whole grouping with one keystroke
- **Where:** p. 244 (§23.3.2; `C-M-q`)
- **Insight:** `C-M-q` reindents every line inside one parenthetical grouping without moving its first line; `C-u TAB` shifts a grouping rigidly.
- **Why it matters:** "Reindent this whole form" is the most useful structural cleanup and pairs with paste/transpose. kec-mode inherits it; nEmacs should expose at least "reindent current top-level form" since manual re-spacing is painful on 34 keys.
- **Goal:** both
- **Applicability:** Direct

### Balanced-expression motion/kill is the structural-editing core
- **Where:** pp. 246–247 (§23.4.1)
- **Insight:** `forward-sexp`/`backward-sexp` (`C-M-f`/`C-M-b`) move over a whole balanced expression (or symbol/string/number); `kill-sexp`, `transpose-sexps`, `mark-sexp` operate by sexp. `backward-sexp` also moves over Lisp prefix chars (quote, backquote, comma).
- **Why it matters:** This *is* what "nEmacs is a structural editor" means — operate on whole s-expressions, not characters. The must-have nEmacs command set and kec-mode baseline; KEC's quote/quasiquote/unquote prefixes map directly onto the prefix-skipping behavior.
- **Goal:** both
- **Applicability:** Direct

### Tree navigation: up/down and forward/backward by list
- **Where:** p. 248 (§23.4.2)
- **Insight:** `forward-list`/`backward-list` (`C-M-n`/`C-M-p`) skip whole groups at one level; `backward-up-list` (`C-M-u`) climbs out; `down-list` (`C-M-d`) descends in. They ignore parens in strings/comments via the syntax table.
- **Why it matters:** Up/down-list turns a flat buffer into a navigable tree — essential editing deeply nested KEC Lisp on a small screen where you can't see the whole form. nEmacs's structural promise depends on "go to enclosing form" / "enter this form" as first-class moves.
- **Goal:** both
- **Applicability:** Direct

### Matching-paren feedback: blink, Show Paren, Electric Pair
- **Where:** pp. 248–249 (§23.4.3); `check-parens` p. 246
- **Insight:** Typing a close delimiter flashes/echoes its match; Show Paren mode highlights both delimiters when point is on one; Electric Pair auto-inserts the close and skips an existing one. `check-parens` does a buffer-wide balance check.
- **Why it matters:** On a monochrome amber grid with no mouse, live paren feedback is the main defense against unbalanced KEC Lisp (`nil` is the empty list, so a stray paren silently changes meaning). nEmacs should implement Show-Paren (invert the matching cell) and consider electric-pair so the keyboard never produces unbalanced source; run `check-parens` before `kec build`.
- **Goal:** both
- **Applicability:** Adapt

### Lisp comment conventions are semicolon-count-driven
- **Where:** pp. 249, 251–252 (§23.5)
- **Insight:** `;;` comments indent as code, `;;;` align to the left margin; `M-;` (`comment-dwim`) inserts/aligns/region-toggles; in Lisp mode `comment-start` is `"; "`, `comment-end` empty; `comment-start-skip` is the recognizer regexp.
- **Why it matters:** kec-mode just sets `comment-start`/`comment-end`/`comment-start-skip` and inherits all of `comment-dwim` — near-zero work. nEmacs can hardcode the single-`;` rule; the `;;` vs `;;;` distinction is nice-to-have, not load-bearing.
- **Goal:** both
- **Applicability:** Direct

### In-buffer symbol completion via `completion-at-point`
- **Where:** p. 254 (§23.8)
- **Insight:** `C-M-i` / `M-TAB` runs `completion-at-point`; in Emacs Lisp mode it completes against names *defined in the current session*, falling back to tags/Semantic otherwise, behaving like minibuffer completion.
- **Why it matters:** Because KEC Core is loaded into a live `kec_State`, kec-mode's best completion source is the running inferior `kec` process's symbol table (query over the REPL), not static parsing — the "current session" model. nEmacs has the interpreter in-process, so it can complete straight from the live environment — strong fit for multi-tap entry.
- **Goal:** both
- **Applicability:** Adapt

### Three Lisp modes encode the eval-target decision
- **Where:** p. 276 (§24.7), p. 279
- **Insight:** `emacs-lisp-mode` evals the current form *in Emacs itself*; `lisp-interaction-mode` evals-and-inserts; `lisp-mode` evals the form *in an external Lisp*; `inferior-lisp-mode` is the interactive external session. `.l`/`.lsp`/`.lisp` default to `lisp-mode`.
- **Why it matters:** The central fork for kec-mode. KEC runs in a separate `kec` process → kec-mode is the `lisp-mode` archetype (send form to inferior process), *not* the `emacs-lisp-mode` self-eval archetype. `.lsp` already maps to `lisp-mode`, so kec-mode must claim it. nEmacs is the opposite — interpreter in-process → behaves like `emacs-lisp-mode` (eval in its own image).
- **Goal:** both
- **Applicability:** Direct

### Buffer-eval command granularity: expression / defun / region / buffer
- **Where:** p. 278 (§24.9)
- **Insight:** A graded eval menu: `eval-expression` (`M-:`, minibuffer), `eval-last-sexp` (`C-x C-e`, form before point → echo area), `eval-defun` (`C-M-x`, enclosing top-level form), `eval-region`, `eval-buffer`.
- **Why it matters:** The exact command set kec-mode should expose, each mapped to a `kec eval`/send-region operation (the CLI's `eval`/`run` cover these). nEmacs should mirror at least send-last-sexp and send-defun against its in-process interpreter. "Echo area for last-sexp, insert with prefix arg" is a clean UX default.
- **Goal:** both
- **Applicability:** Direct

### `*scratch*` / Lisp Interaction: eval-and-print as a lightweight REPL
- **Where:** p. 279 (§24.10)
- **Insight:** `*scratch*` in `lisp-interaction-mode` binds `C-j` to eval the preceding sexp and *insert its value inline*, building a transcript of expressions and results in an ordinary editable buffer.
- **Why it matters:** Perfect for nEmacs: no separate process, no terminal pane — an editable buffer where evaluating a form appends its result, fitting an 80×25 amber grid and arena memory far better than a full comint REPL. kec-mode can offer this too as a scratch buffer alongside the inferior-process REPL.
- **Goal:** both
- **Applicability:** Direct

### Inferior Lisp: a comint subprocess REPL is the template for wiring `kec`
- **Where:** pp. 279–280 (§24.11)
- **Insight:** `run-lisp` starts the external `lisp` program as a subprocess; I/O flows through `*inferior-lisp*` (Lisp mode + comint). `inferior-lisp-program` names the binary; from a source buffer `C-M-x` (`lisp-eval-defun`) sends the top-level form to that subprocess.
- **Why it matters:** The literal blueprint for kec-mode's REPL: set `inferior-lisp-program` to `kec repl`, run under comint, rebind send-defun/region onto it — reusing battle-tested comint plumbing instead of inventing a protocol. The CLI's `repl`/`run`/`eval` subcommands map onto run-lisp / lisp-eval-defun / eval-expression.
- **Goal:** kec-mode
- **Applicability:** Direct

### Bonus structural-display features: which-function, hideshow, prettify
- **Where:** pp. 243, 253–254, 256 (§23.2.4, §23.7, §23.11)
- **Insight:** Which Function mode shows the current defun's name in the mode line; Hideshow folds blocks (parens in Lisp) to an ellipsis; Prettify Symbols replaces `lambda` with a glyph for display only.
- **Why it matters:** All three are screen-real-estate wins for the cramped nEmacs grid: which-function as a Row-0 hint, hideshow folding large forms so more fits in 25 rows, prettify mapping KEC `lambda`/`fn` to a compact Code Page glyph. kec-mode gets all three from `prog-mode` nearly free; for nEmacs they're aspirational polish.
- **Goal:** both
- **Applicability:** Aspirational

## Chapter 33 — Customization: Variables, Keymaps, Init (book pp. 412–442)

Emacs's extensibility architecture: behavior is parameterized by typed, self-describing **variables** (adjusted globally, per-buffer, or via **hooks** without forking code); keys are bound to named commands through layered **keymaps** that resolve most-specific → global; all configured by executable **Lisp** in an init file. For nEmacs the load-bearing lesson is the trinity — *keymaps are data, commands are named Lisp functions, configuration is Lisp* — the substrate that lets KEC Lisp drive a reprogrammable editor, and the keymap layering is the native mechanism for ADR-0016's context-sensitive 34-key dispatch.

### Customizable variables are typed, self-describing settings
- **Where:** p. 412 (§33.1)
- **Insight:** Most settings are "customizable variables" carrying a type, default, doc string, and customization state; a generated Customize UI reads that metadata to render editors and validate input ("will not install an unacceptable value").
- **Why it matters:** nEmacs won't ship the Customize GUI, but the *idea* — a registry of variables that know their type/default/doc — is what lets `C-h v`-style help, validation, and a future SYS-tab settings picker exist without bespoke code per option. Capture the metadata model even on 128×75.
- **Goal:** both
- **Applicability:** Adapt

### A variable is a Lisp symbol with a value, named to describe its role
- **Where:** p. 420 (§33.2)
- **Insight:** A variable is a symbol holding a value; the name describes its role; type matters by convention — `nil` is the sole "off"/false value, `t` the canonical "true"; many variables just switch nil vs non-nil.
- **Why it matters:** Maps 1:1 onto KEC Lisp, where `nil` is already the only false value (and the empty list) and `:keyword`s are ordinary symbols. nEmacs config variables can *be* KEC globals with no new type system — `set`/`=` semantics already fit.
- **Goal:** nEmacs
- **Applicability:** Direct

### Buffer-local vs global variables let one setting mean different things per surface
- **Where:** pp. 423–424 (§33.2.3)
- **Insight:** Almost any variable can be made buffer-local (`make-local-variable`), independent of its global value; `setq-default`/`default-value` reach the global. Major/minor modes set variables locally so a mode change in one buffer can't leak to others.
- **Why it matters:** nEmacs surfaces (REPL, editor, mission board, bare-deck tabs) need the same variable to take different values per context without globals colliding. The buffer-local/global split is the disciplined pattern, and it pairs with arena-bounded state since locals are scoped, not duplicated globally.
- **Goal:** both
- **Applicability:** Adapt

### Hooks: adjust behavior by adding functions to a list, never forking code
- **Where:** p. 422 (§33.2.2)
- **Insight:** A hook is a variable holding a list of functions run on a defined occasion (`add-hook`/`remove-hook`); "normal" hooks call each with no args, "abnormal" (`-functions`) pass args/use return values. Mode hooks fire as the last init step.
- **Why it matters:** The core "extend without modifying" lever. nEmacs gains the same composability — a surface/mode raises a hook, carts/config push KEC lambdas onto it — so context behaviors stack instead of branching in C. Keep hook functions small (shallow GC stack).
- **Goal:** both
- **Applicability:** Direct

### Buffer-local hooks with the `t` sentinel compose local + global behavior
- **Where:** p. 423 (§33.2.2)
- **Insight:** A buffer-local hook is used instead of the global one — *unless* it contains the element `t`, in which case the global hook functions also run. A buffer can add local behavior and still inherit shared behavior, or fully override.
- **Why it matters:** A precise knob for nEmacs context-polymorphism: a surface layers surface-specific reactions on top of shared deck-wide ones (the `t`-includes-global pattern), or shadows them entirely — without a second dispatch mechanism. Same primitive, two policies.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Keymaps are data structures mapping key sequences to named command functions
- **Where:** p. 429 (§33.3.1)
- **Insight:** Every command is a Lisp function flagged for interactive use; a key gets meaning from its *binding* in a keymap. Keymaps are first-class data; Emacs has many. `g` is bound to `self-insert-command`; `C-a` to its command — all by data, not hardcoding.
- **Why it matters:** THE blueprint. Make nEmacs's key→command table a KEC data structure mapping input events to named KEC functions, not a C `switch`. That single decision makes the editor reprogrammable live and is the substrate ADR-0008 assumes.
- **Goal:** nEmacs
- **Applicability:** Direct

### Key lookup resolves through layered maps: minor → major(local) → global
- **Where:** p. 430 (§33.3.3)
- **Insight:** The global map is always in effect; each major mode supplies a local map overriding some global keys; minor modes add maps overriding both; buffer text can carry its own map. Lookup checks enabled minor-mode maps first, then major-mode, then global — first whole-sequence match wins.
- **Why it matters:** This layering *is* the native answer to ADR-0016's context-sensitive keys. Model each surface/mode as a local keymap and overlay transient modes (multi-tap entry, seed-capture, isearch) as higher-priority maps, so a key like TERM means one thing by default and another when a higher layer is active — no special-casing, just precedence.
- **Goal:** nEmacs
- **Applicability:** Direct

### Prefix keys are themselves keymaps — sequences chain map lookups
- **Where:** pp. 429–430 (§33.3.2)
- **Insight:** Each keymap records single events; a prefix key (`C-x`, `ESC`, `C-c`) is bound to *another keymap* that looks up the next event. Prefix maps live in named variables (`ctl-x-map`, `esc-map`). A local map can redefine a key as a prefix; local + global prefix definitions combine.
- **Why it matters:** On a 34-key split with layers, nEmacs needs multi-key sequences (a leader model) to reach a large command set from few keys. Nested-keymap prefixes give unlimited reach with a tiny keyboard, and "local adds a prefix, global bindings under it still resolve" lets surfaces extend a shared leader without redefining the tree.
- **Goal:** nEmacs
- **Applicability:** Direct

### Function keys, modifiers, non-character events are all just symbols in the same map
- **Where:** pp. 433–434 (§33.3.7–33.3.8)
- **Insight:** Function keys are Lisp symbols (`LEFT`, `f5`), modifiers are prefixes (`C-`, `M-`, `s-`/`H-`), Control-modified letters are case-insensitive; vectors (`[f7]`) express events strings can't, and non-ASCII keys *must* use vector form.
- **Why it matters:** nEmacs's modifier-layer keyboard and any chorded/special inputs slot into the *same* keymap abstraction — no separate code path for "special" keys, just more symbols. The string-vs-vector distinction is worth mirroring so binding logic stays uniform across the split layout.
- **Goal:** nEmacs
- **Applicability:** Adapt

### Special keys translate to ASCII *only if unbound* — bind to override
- **Where:** pp. 434–435 (§33.3.9)
- **Insight:** TAB/RET/ESC are function-key symbols (`tab`, `return`, `escape`) that auto-translate to their ASCII control char *only when they have no binding of their own*. Bind the symbol → intercept; leave unbound → falls through to the control character.
- **Why it matters:** A clean model for nEmacs's context-sensitive keys: a key carries a default meaning that a surface can pre-empt by binding the higher-priority form, else it falls through. The same "bind to specialize, else inherit" pattern that makes TERM polymorphic without a god-switch.
- **Goal:** nEmacs
- **Applicability:** Adapt

### The init file is configuration as executable Lisp
- **Where:** pp. 437–441 (§33.4)
- **Insight:** Startup loads an init file of ordinary Lisp: `setq` (current/local) vs `setq-default` (global), enabling minor modes by *calling the mode command* (not `setq`-ing its variable), `global-set-key`/`define-key`, `add-hook`, and `(if (fboundp 'x) …)` / `condition-case` guards for missing features.
- **Why it matters:** nEmacs config should be KEC Lisp evaluated at startup, not a parsed config format — the same code that defines commands also configures them. The `setq` vs `setq-default` distinction and "call the mode command, don't poke its variable" are real gotchas; `fboundp`/`condition-case` guards translate directly to KEC facilities that already exist — `bound?` (host) for the feature check and `condition-case`/`ignore-errors` (shipped in `core/36-recover` over the existing `try`/`raise` catch seam, ADR-0001) for capability/profile differences. (Feature presence also has `provide`/`provided?`/`require`, `runtime/kec.c`.) For kec-mode, this *is* the user-facing extension surface.
- **Goal:** both
- **Applicability:** Direct

### `kbd` notation + bind-time quoting: keys are data, commands are symbols
- **Where:** pp. 432, 440 (§33.3.6)
- **Insight:** `(global-set-key (kbd "C-z") 'shell)` — `kbd` turns a readable key string into the event representation; the quote marks the command a *constant symbol* (omit it and Lisp evaluates `shell` as a variable → error). `define-key MAP KEY CMD` binds into a specific map; freeing a binding is required before reusing a key as a prefix.
- **Why it matters:** nEmacs needs an equivalent readable key-spec parser (a `kbd`) so authors write `"LSHIFT-2"`-style strings, not raw scancodes; the symbol-vs-value quoting maps onto KEC's quote/`set` semantics. "Unset before re-prefixing" is a concrete bootstrapping constraint for building the layered map.
- **Goal:** both
- **Applicability:** Adapt

### Disabling commands and `safe-local-variable` gating model capability tiers
- **Where:** pp. 426–427, 437 (§33.2.4.2, §33.3.11)
- **Insight:** File-local variables are vetted against a known-safe set; `eval`/`load-path` are "risky" and require confirmation (`enable-local-variables`). A command can carry a `disabled` property so invoking it interactively asks for confirmation.
- **Why it matters:** nEmacs runs untrusted cart Lisp under SANDBOX vs FULL profiles; "data is gated by a safety predicate, dangerous operations require confirmation" is a precedent for deciding which config a cart may set and which commands need a guard. The per-command `disabled` flag is a lightweight pattern for fencing destructive deck operations.
- **Goal:** nEmacs
- **Applicability:** Adapt

---

## What to skip (irrelevant to an embedded clone)

These chapters are out of scope for nEmacs (mostly GUI, host-OS, or large-app
features) and were not mined: Ch 15 File Handling (mostly — keep only the
visit/save/auto-save *concepts*), Ch 18 Frames & Graphical Displays (mouse, fonts,
scroll bars, tooltips, dialogs — **no mouse, no frames**), Ch 19 International Character
Set Support (input methods, coding systems, bidi — the KN-86 Code Page is fixed), Ch
22 Commands for Human Languages (filling, Outline, Org, TeX, tables — prose authoring,
not the use case), Ch 25 Maintaining Large Programs (VC, tags, ChangeLog), Ch 26
Abbrevs (possible nice-to-have, not core), Ch 27 Dired, Ch 28 Calendar/Diary, Ch
29–30 Mail/Rmail, Ch 31 Misc, Ch 32 Emacs Lisp Packages (package.el), Ch 34 Common
Problems, and Appendices A–G + the GNU Manifesto. kec-mode, running inside desktop
Emacs, gets all of that machinery for free and must not reimplement it.

---

## Build roadmaps (derived from the notes)

### nEmacs — suggested MVP build order

Each layer below depends on the ones above it; this order front-loads the
architecture-defining decisions so later features fall out of them.

1. **The command/keymap core.** Key event → layered keymap lookup (minor→major→global)
   → named KEC function. Self-insert vs command dispatch. Prefix keys = nested keymaps. A
   `kbd`-style key-spec parser. *This is the foundation — get it right first.* (§2.3; §33.3)
2. **Buffer + point + mark.** Buffer struct (text + point + major mode + local-var bag);
   point belongs to the view; mark + `mark_active`; mark ring (fixed-capacity offset ring).
   Explicit create/switch/kill lifecycle with `kill-buffer-hook`. (§16; §8)
3. **Kill ring + yank/yank-pop.** Bounded text-block ring + last-yank index; kill vs delete
   convention; append-consecutive-kills; track "last command" in the loop. (§9)
4. **Linear undo, byte-capped.** One stack + sequence-breaking flag; coalesce insertions at
   word/commit boundaries; discard oldest at the arena-reset boundary. (§13.1)
5. **Minibuffer + completion + M-x.** Reuse the edit buffer in a reserved row; basic-prefix
   completion (candidate sets = data); per-category history; strict reader for commands. (§5; §6)
6. **Display discipline.** Conservative scroll + scroll margins; narrowing-to-defun; faces as
   meaning→monochrome-attribute indirection; JIT-fontify only visible cells; composable,
   self-throttling Row-0/Row-74 status line. (§11)
7. **Isearch** as a transient keymap on the same dispatch path (the full wrap/fail state
   machine + two-stage `C-g`); literal/word/symbol search; defer or bound regexp. (§12)
8. **Modes.** Major mode = personality (keymap+indent), minor modes = composable layers,
   `<mode>-hook` on entry; `kec-lisp-mode` + `repl-mode`. (§20)
9. **Structural Lisp editing** (also serves the "structural editor" promise): sexp motion/kill/
   transpose/mark, up/down-list, Show-Paren (invert matching cell), TAB sexp-indent, in-process
   eval-last-sexp / eval-defun, `*scratch*`-style `C-j` eval-and-insert REPL. (§23; §24.9–24.10)
10. **Power features:** registers; keyboard macros (record/replay the command stream, persist
    named macros per-deck). (§10; §14)

### kec-lisp mode — suggested build order (mostly wiring)

1. **Claim `.lsp` + syntax table + comment vars** (cheap): `auto-mode-alist` entry deriving from
   `prog-mode`; syntax table (parens, `;` comment, string `"`, symbol constituents);
   `comment-start "; "` / `comment-end ""` / `comment-start-skip` → inherits `comment-dwim`;
   `indent-tabs-mode` nil. (§20.3; §23.5; §21.3)
2. **Font-lock keywords:** a keyword table mapping KEC syntax (`set`, `mac`, `fn`, `def`-family,
   `:keywords`, `nil`/`t`, quote/quasiquote) to standard `font-lock-*` faces; honor the column-0
   defun convention. (§11.12)
3. **Indentation:** a `lisp-indent-function`-style indenter + a symbol→rule table giving
   body-indent to KEC special forms; bind TAB. (§23.3)
4. **Structural commands:** mostly free from `prog-mode` (forward/backward/up/down-sexp,
   kill/transpose/mark-sexp); add Show Paren and (optionally) Electric Pair;
   `check-parens` before `kec build`. (§23.4)
5. **Inferior-`kec` REPL via comint:** `inferior-lisp-program` = `kec repl`; `run-kec`;
   rebind send-last-sexp / send-defun / send-region / send-buffer onto the `kec` CLI's
   `eval`/`run`. (§24.11)
6. **Completion-at-point** querying the live inferior process's symbol table (not static
   parsing). (§23.8)

---

*Compiled from a targeted read of the GNU Emacs Manual: Introduction + Chapters 1–14, 16–17, 20–21, 23, 24.7–24.11, and 33 (the editing-model, Lisp-editing, and extensibility chapters). GUI, mail, calendar, dired, VC, i18n, and large-app chapters were deliberately skipped (see "What to skip"). Page citations are to the printed book. Companion to [field-notes-amop.md](field-notes-amop.md) and the runnable [rxi/lite reference implementation](field-notes-rxi-lite.md).*
