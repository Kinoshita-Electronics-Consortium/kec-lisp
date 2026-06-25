---
title: "Field Notes: Writing GNU Emacs Extensions"
description: Reading notes from Bob Glickstein's Writing GNU Emacs Extensions, mined as a KEC-Lisp-vs-Emacs-Lisp gap analysis for knEmacs (the KN-86 on-device editor) and the KEC Lisp stdlib.
---

> Reading notes on Bob Glickstein, *Writing GNU Emacs Extensions* (O'Reilly, 1997;
> ISBN 1-56592-261-1), mined for the **KEC Lisp** project. Where the companion
> [GNU Emacs Manual notes](field-notes-emacs.md) describe what an Emacs *is* (the
> user-facing model), this book teaches how to **program one in Lisp** — a
> tutorial that builds up from a one-line `.emacs` tweak to a complete crossword
> editor. That makes it the right source for the question driving this sprint:
> *what does the KEC Lisp standard library / extension layer need so it can host
> **knEmacs** (formerly nEmacs, "Ka-Nee-Macs") — an Emacs-like on-device editor +
> REPL built into the KN-86 nOSh runtime over KEC Lisp?*
>
> Three consumers, in priority order:
> 1. **KEC Lisp language & stdlib** — for every Emacs Lisp facility a worked
>    example leans on, this file records whether KEC already **Has** it, **Partly**
>    has it (present but semantically divergent — a porting hazard), or it's a
>    **Gap**. That gap table is the centerpiece.
> 2. **knEmacs** — the editor itself: the command/keymap/mode/buffer machinery the
>    book builds is the literal blueprint, even though most of it lives *above* the
>    language (firmware over KEC, bound through the `kec_bind_fe` FFI seam).
> 3. **kec-mode** — an eventual desktop GNU Emacs major mode for `.lsp` files.
>    Minor relevance; noted where it falls out for free.

**The big takeaway up front.** Glickstein's thesis — stated in the Preface and
proven by Chapter 10 — is that *"Emacs is a general-purpose, interactive
application builder… a user-interface toolkit"* whose ceiling is set by the
primitives the substrate exposes, not by any built-in feature list. That is
exactly the bet knEmacs makes on KEC Lisp. And the happy result of grounding the
gap analysis in the **actual** KEC source (see below) is that KEC Lisp is already
a *much* closer match to Emacs Lisp than a glance at the kernel suggests: the
macro/quasiquote/`eval`/`apply`/reflection/`gensym`/`equal?` machinery this book
treats as the hard part is **present** — as is the error-catch seam (`try`/`raise`)
and the feature registry (`provide`/`require`). The remaining language gaps are few
and sharply defined: **Lisp-level error recovery** was the first-pass headline gap,
but it turned out to be Core macros over `try`/`raise` and **shipped in ADR-0001**
(`core/36-recover`), leaving **vectors** (and the container tier generally) as the
chief remaining hole.

**How to read this.** Each note cites the **printed book page** (`p. NN`, from the
red `Page NN` markers in the PDF). Tags:

- **Goal** = `knEmacs` / `kec-lisp` (language & stdlib) / `kec-mode` / `both` / `all`.
- **KEC status** = **Have** (KEC already provides the language facility) / **Partial**
  (present but divergent — a documented hazard) / **Gap** (a real language/stdlib
  hole) / **N-A** (an *editor/firmware* concern, not a language feature — knEmacs
  binds it through the FFI seam).
- **Applicability** = **Direct** (adopt the pattern as-is) / **Adapt** (transfers but
  must change for the device or the FFI boundary) / **Aspirational** / **Avoid**.

Source: `Writing GNU Emacs Extensions.pdf` (219 PDF pp.). The PDF↔book offset
drifts (≈ +11 in the front matter toward ≈ 0 by the appendices), so all citations
are to the **printed** page from the red markers, never the PDF index. **KEC-status
verdicts were checked against the actual `kernel/`, `core/`, `host/`, and
`runtime/kec.c` on 2026-06-21**, not inferred from docs — several constructs a
casual reading would call "missing" are in fact present (`gensym`, `equal?`,
`let*`, `when`/`unless`/`dolist`/`dotimes`, `apply`, `eval`, `macroexpand-1`,
`read-string`, `substring`/`string-ref`). Companion to
[field-notes-emacs.md](field-notes-emacs.md) and
[field-notes-amop.md](field-notes-amop.md).

---

## Top cross-cutting lessons

Ranked by value to KEC. Each links to the detailed notes below.

1. **Lisp-level error recovery let a real editor restore point on a
   failed command and keep its command loop/REPL alive** (Ch 8 pp. 119–121; Ch 10 pp. 159–162).
   `unwind-protect` (guaranteed cleanup on error/quit), `condition-case`, and
   `ignore-errors` (catch-and-handle) are the forms `save-excursion`/`save-restriction`
   (Ch 4, Ch 9) are *defined* in terms of. **First-pass gap analysis was wrong about
   the cost.** The catch side already exists: `(try thunk)` returns the thunk's value
   or an error value `(:error . message)` (`runtime/kec.c`), on the same setjmp/longjmp
   seam `kec.h` uses, alongside the raise side `error`/`error?`/`error-message`
   (`core/35-error`). So these are **Core macros over `try`/`raise`, not a kernel/
   interpreter change** — and they are now **shipped** in `core/36-recover` (ADR-0001):
   `unwind-protect` runs cleanup on both paths and re-raises (message-only);
   `condition-case` is message-based catch-and-handle; `ignore-errors` yields `nil`.

2. **A command is an ordinary function + an `interactive` declaration — don't fork the function type** (Ch 1 p. 13; Ch 2 pp. 15–17).
   The same function stays callable from Lisp *and* from a key/`M-x`; `interactive`
   is metadata the dispatcher reads to harvest arguments. knEmacs should tag ordinary
   KEC functions with command metadata (a registry or plist) and harvest interactive
   args in the runtime loop — never create a separate "command" object. The
   `interactive` spec being *either* a code-letter string *or* an evaluated expression
   that returns the argument list (Ch 2 pp. 32–33) is the flexible variant to copy,
   and KEC's `eval`/`apply` already support it.

3. **Vectors are the keystone *data-structure* gap** (Ch 10 pp. 135–137; App A pp. 189–191).
   Emacs keymaps, char-tables, and any screen/line grid or ring want O(1)
   random access. KEC's Fe kernel has **no vector type** — only cons lists, which are
   O(n) per access and churn the arena. Sparse keymaps can be alists, but the cell
   grid, undo buffer, and dense key layers really want `vector`/`aref`/`aset`. A
   fixed-size, C-backed vector primitive is very arena-friendly. **High priority.**

4. **The minor/major-mode recipe is convention over machinery — and maps onto KEC's macro system** (Ch 7 pp. 97–99; Ch 9 pp. 123–125, 131–132).
   A mode is "just" a function that resets buffer-local state, sets two well-known
   variables, installs a keymap, and runs a hook. `define-derived-mode` (mode
   inheritance) is itself *a macro* — exactly what KEC's `mac` + quasiquote +
   `macroexpand-1` are for. knEmacs can author its own `define-minor-mode` /
   `define-derived-mode` *in KEC Lisp*; the buffer/keymap primitives underneath are
   the FFI seam.

5. **Keymaps are nested data; key lookup is data-driven** (Ch 9 p. 128; Ch 10 pp. 151–154).
   "A keymap is a Lisp data structure that maps keystrokes to commands"; prefix keys
   are *nested keymaps*; precedence is minor-map → local(major) → global. This is the
   native answer to the KN-86's context-sensitive 34-key dispatch (ADR-0016). Model
   keymaps as nested alists (KEC has `core/25-alist`), sparse-by-default for the
   memory-bounded device, with a dense (vector) representation only for hot full
   layers — once vectors exist (lesson 3).

6. **KEC Lisp is closer to Emacs Lisp than it looks — but four divergences will silently bite ported code** (Ch 1, Ch 2, App A).
   Assignment is **`set`, not `setq`/`=`** (and `=`/`==` mean equality); **numbers are
   single-precision float** (no integer type, exact ≤ ±2²⁴, `/` is float division);
   `=`/`is` compare **pairs by identity** (use `equal?` for contents); and KEC is a
   **Lisp-1** (one binding per symbol) where Emacs is a Lisp-2. None of these block
   knEmacs, but every one is a footgun for copy-pasted elisp and belongs loudly in the
   knEmacs/kec-mode authoring docs. (`nil`-only-falsehood and `0`/`""`-truthy, by
   contrast, match *exactly*.)

7. **Markers, not integers, for positions that survive edits** (Ch 3 pp. 45–47; Ch 8 p. 121).
   A raw integer offset goes stale the moment text is inserted before it; a *marker*
   rides along. This is a firmware buffer-object concern (KEC just passes the opaque
   value), but the design rules transfer verbatim: functions that take positions
   should accept *either* an integer or a marker, and markers are expensive — reuse
   them and detach with `(set-marker m nil)` (acute on the arena/`GCSTACKSIZE`-256
   device).

8. **Reconcile at command boundaries, not per event** (Ch 4 pp. 65–70; Ch 10 pp. 159–162).
   The modifystamp and crossword examples both converge on: do cheap work on every
   change, defer expensive reconciliation to a once-per-command hook
   (`post-command-hook`), and guard against hook re-entrancy (a hook that edits the
   buffer re-triggers itself). This is the governing discipline for *any* per-keystroke
   handler on the single-threaded, ~20 fps, arena-bounded KN-86 runtime.

9. **Build knEmacs's debugging/discovery tools *in* KEC, on the reflective surface** (Ch 1 pp. 10–11; App B pp. 197–199).
   `apropos` (discovery), Edebug (a source stepper *written in Emacs Lisp*), and ELP
   (a profiler, likewise) exist only because the language can inspect and instrument
   itself. KEC already shipped the seeds — `eval`, `macroexpand-1`, `globals`,
   `fn-params`, `bound?` — so `apropos`/`describe-*` and even a stepping debugger can
   be authored in KEC/firmware without touching the frozen kernel. The one missing
   keystone for instrumentation is *mutable function bindings* (rebind a symbol's
   function to a wrapper) — verify before betting on Edebug/ELP-style tooling.

10. **Capability profiles are the right answer to the "code-in-data" attack** (Ch 5 pp. 79–81).
    Emacs's file-local-variables `eval:` block is a Trojan-horse vector (visiting a
    file runs its code). KEC's `KEC_PROFILE_SANDBOX` vs `FULL` (in `host/host.h`) is a
    structurally stronger defense than Emacs's after-the-fact `enable-local-eval`
    prompts: a cart context simply never gets file/system primitives bound. Read
    declarative cart/save metadata as inert data; gate anything that evaluates.

---

## The KEC Lisp gap analysis

The consolidated verdict, verified against the source tree (2026-06-21). This is
the artifact the stdlib/knEmacs work should be planned against.

### Have — KEC already provides it; adopt the book's pattern directly

| Emacs Lisp facility (book) | KEC Lisp | Where |
|---|---|---|
| s-expr prefix reader, variadic calls, `;` comments | same | `kernel/` |
| `quote` `'`, quasiquote `` ` `` / `,` / `,@` | same | `kernel/`, `core/45-quasiquote` |
| `nil` = false = empty list; `0`/`""` truthy; `t` truthy | identical | `kernel/` |
| `cons`/`car`/`cdr`/`setcar`/`setcdr` | same | `kernel/` |
| `list`/`append`/`reverse`/`length`/`nth`/`member`/`assoc` | same | `core/10-list` |
| `mapcar`/`mapc`/`dolist` HOFs | `map`/`for-each`/`filter`/`fold-left`/`fold-right`/`any?`/`every?`/`remove`/`take`/`drop`/`find`/`count`/`range` | `core/50-hof` |
| `sort` | `sort`/`merge` | `core/70-sort` |
| `if`/`cond`/`and`/`or`/`not`/`while` | same | `kernel/`, `core/40-ctrl` |
| `when`/`unless`/`dotimes`/`dolist`/`case`/`let*`/`letrec` | same | `core/40-ctrl` |
| `progn` (sequencing) | `do` (kernel) / `begin` (`core/40-ctrl`) | — |
| `let` | `let` (but see Partial: top-level binds globally) | `kernel/` |
| `lambda` / `defun` / `defmacro` | `fn` / `defn` / `mac` | `kernel/`, `core/00-def` |
| `macroexpand-1` | same | `runtime/kec.c` |
| `eval`, `apply` | same | `runtime/kec.c` |
| `read` (string → form) | `read-string` | `runtime/kec.c` |
| reflection (`boundp`, symbol enumeration) | `bound?`, `globals`, `fn-params` | `host/host.c` |
| `make-symbol`/`gensym` (uninterned → hygienic macros) | `gensym` | `host/host.c`, used in `core/40-ctrl` |
| structural `equal` (lists by contents) | `equal?` | `core/20-cmp` |
| symbol property *operations* `put`/`get` | `put`/`get`/`put-prop`/`get-prop`/`has?`/`keys`/`values` (plist *data*) | `core/26-plist`, `core/25-alist` |
| strings: `concat`/`length`/`substring`/indexed read/`stringp`/`string=` | `string-append`/`string-length`/`substring`/`string-ref`/`string?`/`=` (structural on strings) | `host/host.c`, `core/60-str` |
| `format` (`%s`-style) | `format` | `core/60-str` |
| literal substring search | `string-search` | `host/host.c` |
| `error` (raise) | `error`/`error?`/`error-message` | `core/35-error` |
| predicate zoo `null`/`consp`/`atom`/`numberp`/`symbolp`/`zerop`/… | `nil?`/`pair?`/`number?`/`symbol?`/`fn?`/`zero?`/`even?`/`odd?`/`char-*?` | `core/30-pred` |
| raw clock | `clock` | `host/host.c` |
| capability gating vs the local-variables Trojan | `KEC_PROFILE_SANDBOX`/`FULL` | `host/host.h` |

### Partial — present but divergent (document loudly for porters)

| Divergence | Detail |
|---|---|
| Assignment keyword | KEC uses **`set`** (and top-level `let` binds globally); `=`/`==` are *equality*. Mechanically rewrite `setq`→`set` when porting. |
| Number model | **Single-precision float only** — no integer type, exact ≤ ±2²⁴; `/` is float division (use `floor` for integer division). Buffer offsets/line counts are safe at device sizes but not "integers." |
| List equality | `=`/`is` compare **pairs by identity**; use `equal?` for structure. (Matches Emacs `eq` vs `equal`.) |
| Namespace | KEC is **Lisp-1** (one binding/symbol); elisp's Lisp-2 "function name can't collide with a variable" idioms don't apply. |
| Symbol metadata | `put`/`get` operate on **plist data**, not symbol-attached property cells. Emulate Emacs's per-symbol `put`/`get` with a global table keyed by symbol. |
| Macro expansion | `macroexpand-1` only — no full `macroexpand` (loop to fixpoint); trivial Core add. |
| Char literals | No `?a` reader syntax; chars are numbers + `char->string`/`string-ref`. |
| String mutation | `string-ref` reads; no `aset`-style in-place mutation — build new strings. |
| Time | `clock` gives a raw value; no `format-time-string` formatter (Lisp-side add). |

### Gap — genuine language/stdlib holes, ranked

> **Update (ADR-0001):** rows 1, 3, and 4 below have **shipped** — they were Core
> macros, not kernel work. `condition-case` / `unwind-protect` / `ignore-errors`
> are in `core/36-recover` (over the existing `try`/`raise`); `prog1` is in
> `core/55-util`; full `macroexpand` is in `core/36-recover`. They are kept in the
> table (struck through) to preserve the original gap analysis; the corrected
> difficulty is shown.

| # | Gap | Why it matters | Difficulty |
|---|---|---|---|
| 1 | ~~**`condition-case` / `unwind-protect` / `ignore-errors`**~~ **(shipped, `core/36-recover`)** | Command loop & REPL must survive a failing command; `save-excursion`/`save-restriction` need cleanup-on-error. The **catch** side `try`/`raise` already existed (`runtime/kec.c`), so these were never kernel work. | **Core `mac` macros over `try`/`raise`** — corrects the first-pass "interpreter/kernel-level" call. |
| 2 | **Vectors** (`vector`/`make-vector`/`aref`/`aset`/`vectorp`) | O(1) keymaps/char-tables, cell grid, rings; lists are O(n) and churn the arena. | Kernel + host primitive; arena-friendly. |
| 3 | ~~**`prog1`** (return-first sequencing)~~ **(shipped, `core/55-util`)** | "do X, return prior state" (undo/swap). | Trivial Core macro over `do`. |
| 4 | ~~**Full `macroexpand`**~~ **(shipped, `core/36-recover`)** | Macro debugging / a future stepper. | Trivial: loop `macroexpand-1`. |
| 5 | **Regex** (`re-search`/`string-match`/`looking-at`/`replace-match`/`regexp-quote`) | Serious search/replace, syntax-driven motion, font-lock, the buffer parser. Only literal `string-search` today; deferred-by-design as the "expensive tier." | Constrained subset in `host/` vs. defer; +`regexp-quote` is mandatory if it lands. |
| 6 | **`autoload`/`eval-after-load`** (lazy load + post-load hooks) | Lazy load once knEmacs userland modules multiply. The **feature registry already exists** — `provide`/`provided?`/`require` (`runtime/kec.c`) — so only the *lazy* layer remains. | `autoload` needs a kernel unbound-symbol hook (aspirational); `eval-after-load` is a small Core add over the registry. |
| — | **`apply`/`eval`/`read-string`/`gensym`/`equal?`/`try`/`raise`/`provide`/`require` — NOT gaps** | Listed only to correct the common misconception: these are all present (`runtime/kec.c`, `host/`, `core/`). `try`/`raise` is the error-catch seam; `provide`/`require` is the feature registry. | — |

### N-A — editor/firmware layer, bound through the FFI seam (not the language)

Buffers · points · markers · regions · mark/kill rings · linear undo · keymaps as
*live editor state* & key dispatch · `interactive` arg harvesting · prefix args
(`current-prefix-arg`/`prefix-numeric-value`/`this-command-keys`) · command-loop
state (`this-command`/`last-command`) & `post-command-hook` · major/minor **modes**,
**buffer-local variables**, mode hooks (`run-hooks`/`add-hook`) · **change hooks**
(`after-change-functions`/`first-change-hook`) · **narrowing** · display/faces ·
**syntax tables** (`char-syntax`/`skip-syntax-forward`) · subprocesses
(`call-process`/`start-process` — no device process model). KEC supplies the
substrate (first-class fns, lists/alists, `mac`, `eval`/`apply`, reflection) to
*build* these; the primitives themselves are firmware registered via `kec_bind_fe`.

---

## Field notes by chapter

## Chapter 1 — Customizing Emacs (book pp. 1–12)

The gentle on-ramp: the BACKSPACE/DELETE problem motivates customization, which
becomes a vehicle for a Lisp primer (prefix notation, lists, quoting, symbols),
key rebinding (`global-set-key`, key-string notation), four ways to evaluate Lisp,
and `apropos`. Almost every "basic" here has a direct KEC analog with a few telling
deltas.

### Customization is just running Lisp — and the editor is its extension language
- **Where:** p. 1 (intro); p. 8 (`.emacs`)
- **Insight:** *"There's almost nothing you can't customize in Emacs by writing some Emacs Lisp and putting it in `.emacs`."* The first customization — moving a command between keys — is a single `global-set-key` call; Emacs reads and runs `.emacs` at startup.
- **Why it matters (KEC):** knEmacs's `.emacs` equivalent is a per-deck KEC init file `eval`'d at editor start through the `kec.h` embedding API. KEC has `eval` + the FFI seam; what's missing is the editor-side keymap to bind into (N-A, firmware). Adopt "the editor is its extension language" as the design law.
- **Goal:** knEmacs · **KEC status:** N-A · **Applicability:** Direct

### Keys are character codes, not labels (BS = 8, DEL = 127)
- **Where:** pp. 1–2 (Backspace and Delete)
- **Insight:** *"To Emacs, what matters isn't the label but the numeric character code."* C-h and BS share a code, which is why Help collides with backspace.
- **Why it matters (KEC):** Directly relevant to the 34-key QMK split: define one canonical key-event representation early and bind commands to logical tokens, not raw scancodes. Firmware/`input-dispatch` territory, not the language.
- **Goal:** knEmacs · **KEC status:** N-A · **Applicability:** Adapt

### The Lisp primer: prefix notation, lists, quoting, self-evaluation
- **Where:** pp. 3–8 (Lisp; Keys and Strings; To What Is C-h Bound?)
- **Insight:** Fully-parenthesized prefix, variadic, no precedence, `;` comments. A list is the universal type. A symbol in head position is a function, elsewhere a variable; `'x` ≡ `(quote x)` suppresses evaluation; strings/numbers/vectors self-evaluate. `(setq x 'help-command)` then `(global-set-key … x)` shows quote-vs-value.
- **Why it matters (KEC):** All present in Fe — reader, quote, quasiquote, self-evaluation. The one teaching delta: **`setq`→`set`** (and top-level `let` binds globally). The structural-vs-identity point matters too — match list-shaped data with `equal?`, not `=`.
- **Goal:** all · **KEC status:** Have (assignment keyword differs) · **Applicability:** Direct

### GC pauses are treated as inherent — KEC's arena + iterative Core sidesteps them
- **Where:** p. 4 (Garbage collection)
- **Insight:** Lisp auto-reclaims memory; the cost is the "Garbage collecting…" stall. *"Later we'll learn programming practices that help reduce garbage collection."*
- **Why it matters (KEC):** KEC is arena-allocated with no GC heap churn and a bounded `GCSTACKSIZE` (256 device / 8192 desktop); writing Core list functions *iteratively* is precisely the "reduce GC" practice Glickstein previews — already internalized. knEmacs buffer code must keep the discipline (no deep recursion over line lists).
- **Goal:** kec-lisp · **KEC status:** Have · **Applicability:** Direct

### Four ways to evaluate Lisp — the menu of REPL surfaces
- **Where:** pp. 8–10 (Evaluating Lisp Expressions)
- **Insight:** `load-file`; `eval-last-sexp` (`C-x C-e`, the sexp left of point); `eval-expression` (`M-:`, minibuffer, ships "disabled" as a novice guard); and `*scratch*` Lisp Interaction where `C-j` evals the prior sexp and *inserts the result inline*.
- **Why it matters (KEC):** This is the knEmacs REPL menu. KEC's CLI already has `repl`/`run FILE`/`eval "EXPR"` mapping to three of these; `read-string` + the in-process interpreter make an `eval-last-sexp` (find the sexp before point, read, eval) and a `*scratch*` inline-eval buffer the two highest-value targets.
- **Goal:** knEmacs · **KEC status:** Partial (have eval/`read-string`/REPL; buffer-eval commands are firmware) · **Applicability:** Direct

### `apropos` + reflection is the keystone of discoverability
- **Where:** pp. 10–11 (Apropos)
- **Insight:** *"Emacs's most important online help facility"* — search every function/variable matching a pattern, with one-line docs; `C-u` also reports key bindings. Works because commands are named functions with docstrings and keymaps are introspectable.
- **Why it matters (KEC):** KEC has `globals` + `fn-params` + `bound?` — exactly the substrate. `apropos`/`describe-*` over the symbol table is the single best early knEmacs feature for a learnable 34-key device. Remaining work: a docstring convention + a substring-filter UI.
- **Goal:** knEmacs · **KEC status:** Have (reflection); Partial (docstrings) · **Applicability:** Direct

### `put` and (Emacs-style) symbol property lists
- **Where:** p. 10 (`(put 'eval-expression 'disabled nil)`)
- **Insight:** `put`/`get` hang metadata off a *symbol* via its property list (developed in Ch 3).
- **Why it matters (KEC):** KEC's `put`/`get` operate on plist *data*, not symbol-attached cells. For command metadata (interactive? disabled? docstring? bindings), use a global table keyed by symbol (`core/25-alist`/`26-plist`). Partial — emulation, not native.
- **Goal:** kec-lisp · **KEC status:** Partial · **Applicability:** Adapt

## Chapter 2 — Simple New Commands (book pp. 13–33)

How to write interactive commands and install them: the anatomy of `(defun …
(interactive …) …)`, prefix-argument flow, and two extension mechanisms — **hooks**
and the **advice** facility — plus a dense run of idioms (`if`/`or`/`and`,
`&optional`, `let`, anonymous `lambda`). Central lesson: a "command" is a thin
interactive wrapper over an ordinary function, callable both ways.

### A command = ordinary function + `interactive`, dual-callable
- **Where:** p. 15
- **Insight:** *"A command is a Lisp function that can be invoked interactively"* via a key or `M-x`; placing `(interactive …)` first promotes it. It stays callable from Lisp normally. *"All commands are Lisp functions"* but not vice-versa.
- **Why it matters (KEC):** Don't fork the function type. Tag KEC functions with command metadata (a registry/plist) and harvest interactive args in the runtime loop; preserve programmatic callability. Substrate is Have; the command layer is firmware.
- **Goal:** knEmacs · **KEC status:** N-A (substrate Have) · **Applicability:** Adapt

### The `interactive` spec — code-letter string *or* an evaluated arg-list
- **Where:** pp. 16–17, 32–33
- **Insight:** `interactive` takes one code-letter string (`"p"` = prefix-as-number, default 1; `"P"` = raw prefix), one letter per arg. *Or* its argument is a non-string expression that is **evaluated** to produce the literal argument list — e.g. `(interactive (list (read-buffer …)))`.
- **Why it matters (KEC):** The evaluated-expression variant is strictly more powerful and the better fit for a device that won't reuse Emacs's `C-u` model — and it needs only `eval` + `list` + `apply`, all Have. Implement knEmacs `interactive` as a KEC thunk returning the arg list, dispatched via `apply`.
- **Goal:** knEmacs · **KEC status:** N-A (eval/apply substrate Have) · **Applicability:** Adapt

### `&optional` parameters; `(or n 1)` as the default idiom
- **Where:** p. 17
- **Insight:** `&optional` makes trailing params default to `nil`, so a command works from Lisp with fewer args; `(or n 1)` supplies a default.
- **Why it matters (KEC):** Verify KEC's arglist surface — Fe uses a dotted-tail rest convention (`(a . rest)`, seen across `core/`), and `min`/`max` take `(a . rest)`. An `&optional`-style optional-arg spelling may be absent; if so the `(or n 1)` idiom (Have) covers defaults, or add an arglist macro. **Verify; likely Partial.**
- **Goal:** kec-lisp · **KEC status:** Partial (rest-args via `.`; `&optional` spelling to verify) · **Applicability:** Adapt

### `nil`/`t`/`or`/`and` truth semantics are identical; predicates return payload
- **Where:** pp. 17–20, 28–29
- **Insight:** `nil` is the sole falsehood, the empty list, and self-evaluating; every non-nil (incl. `0`, `""`) is true. `or` returns the first non-nil value, `and` the last (value-returning, not coerced). A predicate can return *useful payload* as its truth value (`file-symlink-p` returns the link target).
- **Why it matters (KEC):** Identical in KEC (`or`/`and` are value-returning; `core/20-cmp`/`30-pred`). The "return the useful thing, else nil" convention saves an allocation — worth codifying for knEmacs FFI predicates under the arena budget.
- **Goal:** all · **KEC status:** Have · **Applicability:** Direct

### `let` for scoped temporaries — but top-level `let` binds globally in KEC
- **Where:** pp. 28–29
- **Insight:** `(let ((v val) …) body…)` scopes temporaries to the body, avoiding name clashes.
- **Why it matters (KEC):** Inside a function body `let` scopes normally, but KEC's documented kernel delta — **top-level `let` binds globally** — is a porting hazard for elisp pasted at top level. Flag in authoring docs.
- **Goal:** kec-lisp · **KEC status:** Partial · **Applicability:** Adapt

### Hooks — a variable holding a list of zero-arg functions
- **Where:** pp. 25–26
- **Insight:** A hook is a variable whose value is a list of functions run at a defined moment; `add-hook`/`remove-hook` manage it; functions take no args. Discover via `apropos … hook`.
- **Why it matters (KEC):** Maps cleanly: a hook is a global bound to a list of function values; `add-hook` ≈ cons + dedup, `remove-hook` ≈ list filter (use the iterative `core/10-list`/`50-hof` ops). Prefer **named** functions in hooks — because KEC compares pairs by identity, removing an anonymous lambda by value is impossible. The hook *firing* is firmware; the list machinery is Have.
- **Goal:** both · **KEC status:** N-A (firing is firmware; list substrate Have) · **Applicability:** Direct

### Advice — `defadvice` wraps before/after/around any named function
- **Where:** pp. 30–32
- **Insight:** Advice injects code around a function each call (`before`/`after`/`around`); unlike hooks (predefined points), *you* choose which functions to advise. The example overrides only the `interactive` form of `switch-to-buffer`.
- **Why it matters (KEC):** A general extension mechanism, harder than hooks: capture a symbol's current function value, install a wrapper, preserve the original (an `around` needs the original captured in a closure — verify KEC closure capture). Feasible on KEC's substrate (first-class fns, `set`, `globals`, `apply`) but a substantial firmware build — consider hooks-only for knEmacs v1.
- **Goal:** knEmacs · **KEC status:** N-A (substrate Have; no advice facility) · **Applicability:** Adapt

### `defalias`, `progn`, `error`/`format` — small idioms
- **Where:** pp. 22, 26–28
- **Insight:** `defalias` gives a function a second name; `progn` sequences where one expression is expected; `(error "…")` aborts the command to top level; `format` builds the message (`%s`).
- **Why it matters (KEC):** `defalias` is trivial — functions are values, `(set 'new old)`. `progn` ≈ KEC `do`/`begin` (Have). `error` (raise) and `format` are Have (`core/35-error`, `core/60-str`); the *catch* side (`condition-case`) is **Have too** now — shipped in `core/36-recover` over `try`/`raise` (ADR-0001). The "guard before a typed primitive, substitute a friendly message" pattern is right for the FFI seam.
- **Goal:** both · **KEC status:** Have (`defalias`/`progn`/`error`/`format`) · **Applicability:** Direct

## Chapter 3 — Cooperating Commands (book pp. 34–46)

The first move from isolated commands to *systems* that pass state across
invocations. The running `unscroll` example escalates through global variables
(`defvar`), the command-loop variables `last-command`/`this-command`, symbol
property lists, and finally markers. The single most load-bearing chapter for
knEmacs's command loop.

### `defvar` — define a global only if unbound (config-survives-load)
- **Where:** pp. 35–36
- **Insight:** `defvar` assigns the default *only if the variable has no value yet*, so a user's pre-set value survives a later library load (vs `setq`, which always assigns).
- **Why it matters (KEC):** KEC has `set` and `bound?` but no conditional `defvar`. A one-line macro `(if (bound? 'x) nil (set 'x v))` is a high-value Core add for knEmacs config-then-load semantics.
- **Goal:** both · **KEC status:** Partial (trivial macro over `set`+`bound?`) · **Applicability:** Direct

### `last-command` / `this-command` — the command-loop handoff
- **Where:** pp. 35, 37, 43
- **Insight:** `last-command`/`this-command` name the previous/current command; Emacs copies `this-command`→`last-command` after each command, and a command may *rewrite* `this-command` mid-run so successors see a chosen value. `unscroll` uses this so one undo reverses a whole burst of scrolls.
- **Why it matters (KEC):** Pure command-loop state the *host loop* maintains — design knEmacs's dispatch with the two-phase `this-command`/`last-command` handoff from day one (it powers kill-ring append, `yank-pop`, repeat detection). KEC supplies `eq`/`globals`/`set`; the loop is firmware.
- **Goal:** knEmacs · **KEC status:** N-A · **Applicability:** Direct

### Symbol property lists — per-command metadata without O(n²) maintenance
- **Where:** pp. 44–45
- **Insight:** `(put 'scroll-up 'unscrollable t)` / `(get 'scroll-up 'unscrollable)` tag a command via its property list — extensible (new commands just `put` a flag) and collision-free. The data-driven alternative to hard-coding per-command logic.
- **Why it matters (KEC):** KEC symbols have a binding but **no symbol-attached property cell**; `put`/`get` are plist *data* ops. For command attributes, key a global plist/alist by symbol. The open/closed, data-driven pattern is the architectural takeaway. (Adding true symbol plists is a frozen-kernel question — emulate in `core/` first.)
- **Goal:** both · **KEC status:** Partial · **Applicability:** Direct

### Markers — positions that survive edits (and are expensive)
- **Where:** pp. 45–47
- **Insight:** A marker specifies a buffer position like an integer but *moves with edits before it*; saving a raw `point` integer goes stale. `make-marker`/`set-marker`; `goto-char` accepts a marker transparently. Markers cost: every one is updated on every edit, so reuse them and `(set-marker m nil)` to detach before discarding.
- **Why it matters (KEC):** *The* enabling abstraction for point/mark/region/rings. A firmware buffer object; KEC just holds/passes the opaque value (the FFI seam carries foreign values). Two rules transfer: position-taking functions accept **either** int or marker, and the reuse/detach discipline is mandatory under `GCSTACKSIZE`-256.
- **Goal:** knEmacs · **KEC status:** N-A · **Applicability:** Direct

### Guard with a clear `error` before a primitive that fails cryptically
- **Where:** p. 40
- **Insight:** Calling `unscroll` before any scroll passes `nil` to `goto-char` → opaque "Wrong type argument" crash; precede with `(if (not unscroll-point) (error "Cannot unscroll yet"))`. Note `integer-or-marker-p` — a *type predicate* unifying valid positions.
- **Why it matters (KEC):** `error` is Have. The defensive idiom is right for knEmacs commands; if markers land, add an analogous `position?` predicate to `core/30-pred`.
- **Goal:** both · **KEC status:** Have (`error`); Partial (position predicate) · **Applicability:** Direct

## Chapter 4 — Searching and Modifying Buffers (book pp. 47–70)

The most concentrated source of buffer-editing idioms in the book, and the
highest-value chapter for scoping the knEmacs buffer API: the `save-*`
state-restoration trio, literal/regexp search, the find→delete→insert edit cycle,
`regexp-quote`/`replace-match`, and hook-driven automatic edits. Regular
expressions are the clearest KEC gap here.

### `save-excursion` / `save-restriction` / `save-match-data` — memorize → run → restore
- **Where:** pp. 52–55
- **Insight:** Each saves some dynamic state (point; narrowing; match data), runs its body, and restores — so a function can roam the buffer yet leave the caller's view untouched. Code that `widen`s must wrap in `save-restriction`; code that searches internally should wrap in `save-match-data`.
- **Why it matters (KEC):** The #1 macro candidate — and a *correct* implementation needs restore **on non-local exit** (error/quit), i.e. `unwind-protect`, which KEC **now has** (`core/36-recover`, ADR-0001). Argues for **one** generic unwinding mechanism (`unwind-protect`) underwriting all three `save-*` wrappers, rather than three bespoke wrappers. (Also: prefer search primitives that *return* match positions over hidden global match state — fits KEC's value-returning style.)
- **Goal:** both · **KEC status:** Partial (`unwind-protect` now Have, `core/36-recover`; buffer/point primitives are firmware) · **Applicability:** Direct

### The edit cycle: `let` start → search → `delete-region` → `goto-char` → `insert`
- **Where:** pp. 53–55
- **Insight:** Capture `(let ((start (point)))`, find the end, `delete-region`, `goto-char start`, `insert new`. `search-forward STRING &optional BOUND NOERROR` returns `nil` on soft-fail (`NOERROR`); a `while` loop must keep point past each match or loop forever; `match-beginning 0` beats `(- (point) (length …))`.
- **Why it matters (KEC):** Defines the buffer-mutation primitive set knEmacs binds via FFI (`point`/`goto-char`/`insert`/`delete-region`); the composition is plain KEC over `let` (Have). A search primitive returning `nil` for "not found" is idiomatic (nil = the only false value). Prefer match-position accessors over length arithmetic.
- **Goal:** knEmacs · **KEC status:** N-A (primitives firmware) / Have (`let`) · **Applicability:** Adapt

### Regular expressions — the defining KEC gap
- **Where:** pp. 58–64 (Regular Expressions; `re-search-forward`; `regexp-quote`; `replace-match`)
- **Insight:** Full metacharacter set (`.` `[...]` `*` `+` `?` `^` `$` `\|` `\(…\)` submatches 1–9, backrefs, word/buffer assertions); regexps are Lisp strings so backslashes double. `re-search-forward` mirrors `search-forward`. `regexp-quote` escapes user strings before embedding (a `"."` matching "any char" silently deletes the wrong text at save time). `replace-match` replaces by submatch, collapsing find/delete/insert.
- **Why it matters (KEC):** KEC ships **no regex engine** — only literal `string-search`. Writestamps, real search/replace, syntax-driven motion, font-lock, and the Ch 10 buffer parser all lean on it. Decision: a constrained subset in `host/` (anchors + classes + `*`/`+`/`?`, no backrefs) sized for the arena, or literal-only knEmacs. If it lands, `regexp-quote` is mandatory, not optional.
- **Goal:** both · **KEC status:** Gap · **Applicability:** Aspirational

### Save hooks: pick the right one, and "non-nil return claims the write"
- **Where:** pp. 51–56
- **Insight:** To run code at save time pick `local-write-file-hooks` (buffer-local, mode-stable) over the global/`after-save` alternatives. **Gotcha:** a non-nil return from a write-file hook means "I wrote the file myself," suppressing the real save — so the function ends in explicit `nil`.
- **Why it matters (KEC):** Firmware hook infrastructure, but the contract transfers; the "return nil unless you took over" convention is natural where nil is the only false value — and an easy footgun to document in the knEmacs hook spec.
- **Goal:** knEmacs · **KEC status:** N-A · **Applicability:** Adapt

### Modifystamps: cache cheap on every change, do expensive work at save
- **Where:** pp. 65–70
- **Insight:** Three strategies trade precision vs. cost; the winner caches `(current-time)` into a buffer-local on each `after-change-functions` call and uses it at save. A subtle re-entrancy bug: the stamp edit re-fires the change hook — fixed by dynamically rebinding the hook to `nil` for the body, or (better) capturing the value as an argument.
- **Why it matters (KEC):** The precision-vs-cost calculus is exactly the device's. `clock` is Have (raw time); a `format-time-string` is a small add. The re-entrancy lesson is critical for any knEmacs change/redraw loop, and the "capture as argument vs. rebind a global" choice is sharper on KEC given its `let`/global-binding semantics. (`make-local-variable`/buffer-local hooks are firmware.)
- **Goal:** knEmacs · **KEC status:** N-A (hooks firmware); Have (`clock`) · **Applicability:** Adapt

## Chapter 5 — Lisp Files (book pp. 71–80)

Graduating code from one `.emacs` into discrete `.el` libraries: the load path,
`require`/`provide`, `autoload`, byte-compilation, `eval-after-load`, and the
file-local-variables security hole. Maps onto KEC's load/build story — and the
contrasts are as instructive as the matches.

### Idempotent, side-effect-free top level is the library contract
- **Where:** pp. 71–72
- **Insight:** A library must load "at any time, even multiple times, without unwanted side-effects" — no top-level buffer mutation; effects belong behind functions.
- **Why it matters (KEC):** Exactly the contract `(load …)` and `kec build` (which inlines top-level literal `load`s) assume. KEC Core modules already obey it (only `def`/`mac`, no I/O at load). Codify as a rule for cart/userland `.lsp`.
- **Goal:** kec-lisp · **KEC status:** Have (de facto Core convention) · **Applicability:** Direct

### `require`/`provide` and `autoload` — feature guards and lazy load
- **Where:** pp. 74–77
- **Insight:** A file ends with `(provide 'feat)`; callers `(require 'feat)` load it once. `autoload` binds a name to the file that defines it and loads on first call (with optional docstring + interactive flag so `apropos`/help work pre-load).
- **Why it matters (KEC):** **Correction:** the feature registry **already exists** — `provide` / `provided?` / `require` (a global "loaded features" set + guarded `load`, `runtime/kec.c`); feature dedup keys on symbol/string (compared by value — safe). Only the *lazy* layer remains: `autoload` needs a kernel unbound-symbol hook (aspirational), `eval-after-load` is a small Core add over the registry.
- **Goal:** both · **KEC status:** Have (`provide`/`require`); Gap (`autoload`/`eval-after-load`) · **Applicability:** Adapt

### Byte-compilation — KEC deliberately has none
- **Where:** p. 77
- **Insight:** `.el`→`.elc` is compact, faster, opaque, with staleness warnings; `load` prefers `.elc`.
- **Why it matters (KEC):** Recorded to *prevent reintroducing a compile-step expectation*: Fe is a tree-walking interpreter, `kec build` is a **source bundler** (inline + parse-check + one `.kec`), and Core is embedded into the binary via `mkembed`. The performance role bytecode plays in Emacs is filled by embedding + iterative Core.
- **Goal:** kec-lisp · **KEC status:** N-A (no compiler by design) · **Applicability:** Avoid

### `eval-after-load` and file-local-variables (the Trojan-horse)
- **Where:** pp. 77–81
- **Insight:** `eval-after-load` runs a form right after a named file loads (override-after-load). A file's `Local variables:` block sets buffer-locals on visit; values are *quoted* (inert) **except** the `eval:` pseudovariable, which evaluates — a vector for hostile files (delete files, forge mail). Defenses: `enable-local-variables`/`enable-local-eval`.
- **Why it matters (KEC):** Two lessons. (1) The data-vs-code split — read declarative metadata as inert data, gate anything that evaluates — is the discipline for cart/save metadata. (2) Security: KEC's **capability profiles** (`SANDBOX`/`FULL`, `host/host.h`) are a *structurally stronger* defense than Emacs's prompts — a cart context simply never gets file/system primitives. `eval-after-load` itself is a Gap (pairs naturally with `require`/`provide`).
- **Goal:** both · **KEC status:** Have (profiles defend); Gap (`eval-after-load`) · **Applicability:** Adapt

## Chapter 6 — Lists (book pp. 81–94)

The single most language-relevant chapter: cons cells from first principles, the
predicate zoo, the **recursive-vs-iterative** performance lesson, `mapcar`/`assoc`,
`eq`/`equal`, destructive ops, and circular lists. It maps almost 1:1 onto KEC
Core's deliberate iterative design and identity-comparison rule.

### Cons cells, shared structure, dotted/improper lists
- **Where:** pp. 83–85
- **Insight:** A cons holds car+cdr; a list is a chain ending in `nil`; `'(a b c)` ≡ `(cons a (cons b (cons c nil)))`. `(setq y (cdr x))` *shares* structure. `(a . b)` shows non-list cdrs; improper lists have a non-nil last cdr.
- **Why it matters (KEC):** Exactly Fe's model (`setcar`/`setcdr` kernel; `core/10-list`). Shared structure is the foundation of KEC's headline gotcha: `=`/`is` compare **pairs by identity**.
- **Goal:** kec-lisp · **KEC status:** Have · **Applicability:** Direct

### `nil` duality; `(car/cdr nil)` ≡ `nil`; the predicate zoo
- **Where:** pp. 85–86
- **Insight:** `nil` is false ∧ empty list; `(car nil)`/`(cdr nil)` are `nil` "for convenience." `consp`/`atom`/`listp`/`null` partition the type space.
- **Why it matters (KEC):** Identical (`core/30-pred`: `pair?`/`nil?`/…). The `car`/`cdr`-of-nil convenience is what lets `(while lst …)` cdr-down loops stay clean — enabling the iterative design below.
- **Goal:** kec-lisp · **KEC status:** Have · **Applicability:** Direct

### Recursive is elegant; iterative "cdr-ing down" is correct on a bounded stack
- **Where:** pp. 86–88
- **Insight:** The book makes the case explicitly: for linear list work *"a recursive solution is wrong"* — recursion's per-call overhead "should be avoided when possible." The iterative form binds an accumulator and `(while lst … (setq lst (cdr lst)))`.
- **Why it matters (KEC):** A **1:1 match with an intentional KEC decision** — Core list/sequence functions are iterative "so a library call won't exhaust the GC stack on a long list." With `GCSTACKSIZE` 256 on-device this is a hard correctness constraint, not style. The double-recursive `flatten` (pp. 86–87) is the canonical anti-pattern; if knEmacs needs it, write it depth-bounded or with a worklist. Audit `core/10-list`/`50-hof` to confirm every spine traversal is iterative.
- **Goal:** kec-lisp · **KEC status:** Have (deliberate) · **Applicability:** Direct

### `eq` vs `equal` — and KEC's `=` *is* `eq`, with `equal?` for contents
- **Where:** pp. 88–89
- **Insight:** `eq` = same object (pointer); `equal` = same structure/contents (recursive). Two separately-built `(1 2 3)`s are `equal` but not `eq`.
- **Why it matters (KEC):** **Load-bearing, and a correction to a common assumption:** KEC's `=`/`is` behave like Emacs `eq` on pairs — *but KEC does ship a structural `equal?`* (`core/20-cmp`). So content-equality is **Have**, not a gap; the hazard is only that the *default* `=` is identity. Document "use `equal?` for list/tree contents." (Cycle caveat below.)
- **Goal:** both · **KEC status:** Have (`equal?`); Partial (default `=` is identity) · **Applicability:** Direct

### `assoc`/`assq`, `mapcar`, and the dotted-vs-two-cons tradeoff
- **Where:** pp. 88–90
- **Insight:** Alists map keys→values; `assoc` matches with `equal`, `assq` with `eq`. `mapcar` applies a fn over a list into a new list. Dotted entries `(k . v)` halve cons usage vs two-cons `(k v)`.
- **Why it matters (KEC):** `core/25-alist`/`26-plist` + `map` (`core/50-hof`) cover these. On the arena, dotted pairs save memory per entry — relevant for knEmacs keymaps/config tables. String/symbol keys (compared by value) are the safe alist keys; verify an `eq`-keyed fast variant if needed.
- **Goal:** both · **KEC status:** Have (`assoc`/`map`); Partial (verify `assq`-style) · **Applicability:** Direct

### Destructive ops mutate shared structure — fast, hazardous, and *more* attractive on an arena
- **Where:** pp. 90–93
- **Insight:** `append` copies (safe); `nconc`/`setcar`/`setcdr`/`nreverse` splice in place. The killer example: `(setcdr (assoc key alist) new)` is O(1) *and* propagates to all referents, where the copying version is invisible to aliases. `nreverse` leaves the original var mid-chain — `(setq x (nreverse x))`.
- **Why it matters (KEC):** `setcar`/`setcdr` are Have (kernel). On a no-GC-churn arena, in-place mutation that avoids recopying is *more* attractive than on a heap system — the `setcdr`-on-assoc update is the memory-efficient pattern for mutable knEmacs config/state. Document the `nreverse` reassign-or-lose-head footgun if a destructive reverse ships.
- **Goal:** both · **KEC status:** Have (`setcar`/`setcdr`); Partial (verify `nconc`/`nreverse`) · **Applicability:** Direct

### Circular lists — constructible, and a trap for structural traversal
- **Where:** pp. 93–95
- **Insight:** `(setcdr (nthcdr 2 x) x)` makes a cycle; printing or `equal`-comparing it never terminates, while `eq` returns instantly. Cyclic/shared structures are fine if you never *display* them.
- **Why it matters (KEC):** Two implications. (1) KEC's structural `equal?` (and any pretty-printer/`repr`) over a cyclic/shared structure will **hang the device** — worse than Emacs, no `C-g` in a tight C loop. Any deep traversal knEmacs adds needs a depth cap or seen-set; KEC's identity `=` being O(1)/termination-safe is a *feature*. (2) Because `setcar`/`setcdr` make cycles constructible, the guard on a knEmacs inspector/printer is mandatory, not theoretical.
- **Goal:** both · **KEC status:** Gap (cycle-safe traversal/print guards) · **Applicability:** Adapt

## Chapter 7 — Minor Mode (book pp. 95–109)

Builds Refill minor mode and lays out the canonical recipe for bundling a feature
into a togglable, buffer-local mode — plus point/region helpers and the
per-keystroke performance discipline the device demands.

### A minor mode = buffer-local on/off package over a major mode; the four-step recipe
- **Where:** pp. 96–99
- **Insight:** Major mode = one per buffer (Text/Lisp/C); minor modes = orthogonal, independently togglable, mostly buffer-local. Recipe: (1) name; (2) `defvar name-mode nil` + `make-variable-buffer-local`; (3) an interactive `name-mode` toggle command — `(if (null arg) (not mode) (> (prefix-numeric-value arg) 0))`; (4) push `(name-mode " Lighter")` onto `minor-mode-alist`.
- **Why it matters (KEC):** The structural template for knEmacs's mode system. It decomposes into firmware needs (buffer-local vars, interactive registry, mode-line) — but the toggle logic is plain KEC (`if`/`not`/`>`, Have), and a `define-minor-mode` macro can be authored *in KEC* with `mac` once buffer-locals exist.
- **Goal:** knEmacs · **KEC status:** N-A (interactive/mode-line firmware; toggle logic Have) · **Applicability:** Adapt

### Mode body wires/unwires a hook; `save-excursion` probes positions (and is expensive)
- **Where:** pp. 99–103
- **Insight:** Enabling a mode = `add-hook`; disabling = `remove-hook` (with `make-local-hook`, idempotent). `save-excursion` runs a body and restores point — flagged "moderately expensive," so call count is minimized.
- **Why it matters (KEC):** Enable=register-callback / disable=deregister is the event-driven core; needs only first-class fns + a list (Have) plus the firmware event loop. `save-excursion` is reimplemented as a macro in Ch 8 — see there for the language verdict (`unwind-protect`, now Have in `core/36-recover`).
- **Goal:** both · **KEC status:** N-A (hooks/point firmware; macro machinery Have) · **Applicability:** Adapt

### Word/whitespace geometry via the *syntax table*, not hardcoded char sets
- **Where:** pp. 104–106
- **Insight:** `skip-syntax-forward`/`char-syntax` delegate to the buffer's syntax table (word-constituent, whitespace, comment, bracket classes are mode-specific) rather than enumerating characters.
- **Why it matters (KEC):** The right abstraction for knEmacs word/bracket/**sexp** motion (paren matching for a Lisp editor). Firmware data, but it argues for a clean character-classification FFI seam (`char-syntax`/`skip-syntax-forward` primitives over a firmware syntax table). KEC has scalar chars + `char-*?` predicates (`core/30-pred`) but no syntax-table notion — a likely FFI/stdlib add for sexp editing.
- **Goal:** both · **KEC status:** Gap (syntax-table primitives) · **Applicability:** Adapt

### Guard expensive ops behind cheap pre-checks; suppress a hook during its own action
- **Where:** pp. 100–101, 107–109
- **Insight:** Refilling on *every* keystroke is rejected; cheap pre-checks (insertion? same line? still short?) gate the costly `fill-region`. Emacs auto-unsets `after-change-functions` while they run to prevent infinite recursion.
- **Why it matters (KEC):** The governing discipline for any per-keystroke handler on the arena/`GCSTACKSIZE`-256 device, and the re-entrancy lesson for knEmacs's redraw/after-change loop. KEC's iterative Core reflects the same "don't blow the bounded stack" philosophy.
- **Goal:** both · **KEC status:** Partial (philosophy matches; re-entrancy guard firmware) · **Applicability:** Direct

## Chapter 8 — Evaluation and Error Recovery (book pp. 110–121)

The single most language-relevant chapter alongside Ch 6. By rebuilding
`save-excursion` as a macro from scratch, it walks the entire macro toolchain —
controlling *when* evaluation happens, `eval`, `defmacro`, `macroexpand`,
backquote/unquote, `let` vs `let*`, hygiene via gensym — then the error-recovery
forms. KEC already had the machinery for nearly every construct, **including the
error-catch seam** (`try`/`raise`) that the first-pass analysis missed — so the
recovery forms below shipped as Core macros (`core/36-recover`, ADR-0001), not a
kernel change.

### Argument pre-evaluation is *why macros exist*; `eval` holds code as data
- **Where:** pp. 110–112
- **Insight:** A function gets evaluated arguments, so `(limited-save-excursion (beginning-of-line) (point))` would move point before the function could record it — impossible as a function. The workaround uses quoting + `(eval (car exprs))`; the real fix is a macro.
- **Why it matters (KEC):** Pinpoints why knEmacs's `save-*` wrappers must be macros. KEC has `eval` (`runtime/kec.c`) and `mac` — both the workaround and the solution are expressible today.
- **Goal:** kec-lisp · **KEC status:** Have · **Applicability:** Direct

### `defmacro` + `macroexpand`; backquote/unquote/splice
- **Where:** pp. 112–116
- **Insight:** `defmacro` args arrive unevaluated; the body returns an *expansion* that is then evaluated. `macroexpand` shows it. Backquote makes expansions readable: `incr` ≡ `` `(setq ,var (+ ,var 1)) ``; a `&rest` parameter must be *spliced* (`,@`) or you get too many parens.
- **Why it matters (KEC):** Core match: `mac` (= `defmacro`), `macroexpand-1`, and quasiquote `` ` ``/`,`/`,@` (`core/45-quasiquote`) are all Have — KEC even supports the manual `list`/`cons`/`append` alternative. Full `macroexpand` (loop `macroexpand-1` to a fixpoint) **shipped** in `core/36-recover` (ADR-0001). Confirm `mac`'s rest-parameter surface for the `,@` splice rule.
- **Goal:** kec-lisp · **KEC status:** Have (full `macroexpand` shipped) · **Applicability:** Direct

### `let` vs `let*` — evaluation order and dependent bindings
- **Where:** pp. 116–117
- **Insight:** `let` evaluates all inits *before* binding any, in unspecified order (a binding can't reference an earlier one); `let*` evaluates left-to-right, binding each immediately. Using the wrong one is a common bug.
- **Why it matters (KEC):** **Both are Have** (`let` kernel; `let*` `core/40-ctrl`). The order/dependency distinction holds; KEC's separate "top-level `let` binds globally" delta is orthogonal. knEmacs macros that need sequential dependent bindings have `let*`.
- **Goal:** kec-lisp · **KEC status:** Have · **Applicability:** Direct

### Variable capture and the `gensym`/uninterned-symbol fix — hygiene
- **Where:** pp. 117–119
- **Insight:** A macro's internal temp can *capture* a same-named variable in the user's code. The fix: `make-symbol` creates a brand-new *uninterned* symbol, never `eq` to any other, so its binding can't collide.
- **Why it matters (KEC):** **Correction to a tempting "blocker" claim:** KEC ships **`gensym`** (`host/host.c`, used in `core/40-ctrl`), which supplies exactly the capture-proof uninterned symbol. So hygienic macros for knEmacs are **supported today** — author capturing-prone macros with `gensym`'d temps. (There's no `make-symbol` by that name; `gensym` covers the need.)
- **Goal:** kec-lisp · **KEC status:** Have (`gensym`) · **Applicability:** Direct

### `unwind-protect` — guaranteed cleanup on error or quit
- **Where:** pp. 119–121
- **Insight:** An error unwinds the stack to top level; `(unwind-protect NORMAL CLEANUP…)` guarantees CLEANUP runs even if NORMAL was interrupted by an error or `C-g`. This is how the real `save-excursion` restores point on error. In the non-error case it returns NORMAL's value.
- **Why it matters (KEC):** **Shipped (`core/36-recover`, ADR-0001).** A robust editor *must* restore point/state when a command errors. The first-pass call that this "needs interpreter support, can't be a plain `mac` macro" was **wrong**: KEC's catch side `(try thunk)` already existed (`runtime/kec.c`, on the same longjmp seam `kec.h` uses), so `unwind-protect` is exactly a `mac` macro over `try` + the raise side (`core/35-error`) — run cleanup on both paths, re-raise (message-only) on error. The `save-*` wrappers (Ch 4, 7, 9) can now be written correctly.
- **Goal:** kec-lisp · **KEC status:** Have (shipped) · **Applicability:** Direct

### `condition-case` / `ignore-errors` — catch and handle in Lisp
- **Where:** pp. 119–120 (and Ch 10 pp. 159–162)
- **Insight:** `condition-case` is the Lisp try/catch (catch by error type, run a handler); `error`/`signal` raise; `ignore-errors` swallows. `unwind-protect` is cleanup-on-exit; `condition-case` is catch-and-handle.
- **Why it matters (KEC):** **Shipped (`core/36-recover`, ADR-0001), the companion to `unwind-protect`.** knEmacs's REPL and command loop must catch a failing command, show a message, and keep running — that's `condition-case`/`ignore-errors`. Cart/editor Lisp **can** catch now: `(try thunk)` (`runtime/kec.c`) returns the value or `(:error . message)`, and the new macros wrap it — `condition-case` is message-based catch-and-handle (class dispatch deferred), `ignore-errors` yields `nil`. Both ride the same error seam `kec.h` uses, with `core/35-error` (`error`/`error?`/`error-message`) as the raise/inspect side.
- **Goal:** kec-lisp · **KEC status:** Have (shipped) · **Applicability:** Direct

### Record positions as markers, not integers (reprise)
- **Where:** p. 121
- **Insight:** The final refinement swaps `(point)` for `(point-marker)` so the saved position survives edits (same reasoning as Ch 3).
- **Why it matters (KEC):** Firmware buffer object passed opaquely through the FFI seam; point-as-integer is the *wrong* default for anything saved across edits.
- **Goal:** knEmacs · **KEC status:** N-A · **Applicability:** Adapt

## Chapter 9 — A Major Mode (book pp. 122–132)

Builds Quip mode (a file of `%%`-separated quotations) from an explicit skeleton up
through `define-derived-mode`. The literal blueprint for knEmacs major modes:
a mode is a command that resets buffer-local state, sets two variables, installs a
keymap, and runs a hook.

### The major-mode skeleton — convention, not a language construct
- **Where:** pp. 123–125
- **Insight:** A major mode is a command `name-mode` that calls `kill-all-local-variables`, `(setq major-mode 'name-mode)`, `(setq mode-name "Name")`, `(use-local-map name-mode-map)`, `(run-hooks 'name-mode-hook)`; plus `(defvar name-mode-hook nil)` and `(provide 'name)`. Nothing here is special syntax.
- **Why it matters (KEC):** knEmacs should adopt this convention-over-machinery shape: a mode is a KEC function mutating a per-buffer state record and installing a keymap. The mode-function *body* is pure KEC Lisp; the primitives it calls (`kill-all-local-variables`, `use-local-map`, `run-hooks`, the `major-mode`/`mode-name` globals) are the firmware seam. `bound?` (Have) drives the load-guard (`(if (bound? 'quip-mode-map) … build …)`).
- **Goal:** knEmacs · **KEC status:** N-A (substrate Have; mode primitives firmware) · **Applicability:** Direct

### Keymaps are nested data; sparse-by-default; `define-key` builds prefix nesting
- **Where:** pp. 124, 128–129
- **Insight:** *"A keymap is a Lisp data structure that maps keystrokes to commands."* Multi-key sequences are nested keymaps; any key bound to a nested map is a prefix key. `make-sparse-keymap` (alist-like, few bindings) vs `make-keymap` (dense vector). `define-key` mutates a map and auto-creates intermediate prefix maps; `local-set-key` rebinds at runtime.
- **Why it matters (KEC):** The biggest knEmacs stdlib question. A keymap is nested alists keyed by keystroke — KEC ships `core/25-alist`, so a sparse keymap + `define-key` + `copy-keymap` can be authored *entirely in KEC Lisp*, no kernel change. The dense/vector representation waits on the vectors gap (lesson 3). Sparse-by-default fits the memory-bounded 34-key device; lookup compares scalar keystrokes (by value — safe), not whole cells.
- **Goal:** both · **KEC status:** Gap (keymap type; alist substrate Have) · **Applicability:** Direct

### Mode-local structure: redefine "paragraph"/"page" to reuse generic commands
- **Where:** pp. 125–127
- **Insight:** Setting `page-delimiter "^%%$"` makes a "page" a quip, co-opting all of Emacs's built-in page commands (`forward-page`, `narrow-to-page`) for free. Define the data's structure once; reuse generic motion/narrowing.
- **Why it matters (KEC):** A powerful pattern for knEmacs: parameterize generic structural motion by mode-local regexps/predicates. Needs regex (Gap) + generic structure-motion primitives (firmware); the "one definition, reuse generic commands" principle is the free part.
- **Goal:** knEmacs · **KEC status:** Partial (strings Have; regex + generic motion Gap) · **Applicability:** Adapt

### Narrowing and `save-restriction`; `defalias`
- **Where:** pp. 130–131; 127
- **Insight:** Narrowing hides everything outside a region (`narrow-to-region`/`widen`); `point-min`/`point-max` report the narrowed bounds; code needing the whole buffer wraps `(save-restriction (widen) …)`. Narrowing **does not nest**. `defalias` gives reused commands domain names.
- **Why it matters (KEC):** Narrowing is firmware, but `save-restriction` is again the `unwind-protect` shape — now Have (`core/36-recover`, ADR-0001) — argues for one save/restore combinator parameterized by what it saves (point/restriction/buffer). `defalias` is Have (`(set 'new old)`).
- **Goal:** both · **KEC status:** Have (unwind combinator `unwind-protect`, `core/36-recover`; `defalias`) · **Applicability:** Adapt

### Derived modes — `define-derived-mode` is a macro
- **Where:** pp. 131–132
- **Insight:** `(define-derived-mode quip-mode text-mode "Quip" doc body…)` creates the command + `quip-mode-map` + syntax/abbrev tables, calls the parent mode first, applies specializations, runs the hook last. The manual alternative uses `copy-keymap`/`copy-syntax-table`.
- **Why it matters (KEC):** **Strong validation** that KEC's macro system is the right layer for mode definition + inheritance: `define-derived-mode` is itself a macro, exactly what `mac` + quasiquote + `macroexpand-1` (all Have) are for. knEmacs can implement its own derived-mode macro expanding to the skeleton with a parent call spliced in; the supporting `copy-keymap` (deep-copy a nested alist) is a small KEC function.
- **Goal:** both · **KEC status:** Have (macro machinery); Gap (keymaps/`copy-keymap`) · **Applicability:** Direct

## Chapter 10 — A Comprehensive Example (book pp. 133–182)

The capstone: **Crossword mode**, a complete major mode that turns a buffer into a
crossword editor — model, buffer-rendered UI, locked keymap, change reconciliation,
a buffer parser, and an async word-finder. The clearest proof of the
editor-as-application-toolkit thesis, and a complete template for KN-86 text-UI
carts and knEmacs apps.

### Separate the data model from its buffer rendering
- **Where:** pp. 134–142
- **Insight:** The puzzle is a pure data structure (a vector-of-vectors "matrix"); a separate display layer walks it and writes glyphs. The model is the source of truth; the buffer is a view.
- **Why it matters (KEC):** The architecture for any knEmacs app / KN-86 cart with a text UI: cart data lives in Lisp, rendering crosses the FFI boundary (`kec_bind_fe` display primitives). KEC's lists/alists hold the model today; vectors (below) would make it efficient.
- **Goal:** all · **KEC status:** Partial (data Have; display FFI firmware) · **Applicability:** Direct

### A 2D grid needs vectors — the keystone data gap
- **Where:** pp. 135–137
- **Insight:** Elisp has no 2D array, so the author builds one: a vector of *freshly-made* row vectors (the warned-against `(make-vector rows (make-vector cols init))` shares one inner vector by reference). `aref`/`aset` give O(1) access vs list traversal.
- **Why it matters (KEC):** **Concrete language Gap.** The 128×75 / 80×25 cell grid, undo buffer, and rings want O(1) indexed access; on cons lists everything is O(n) and burns the arena. Add a fixed-size, C-backed `vector`/`make-vector`/`aref`/`aset` to `host/` (very arena-friendly). The shared-inner-vector trap is a footgun to document.
- **Goal:** kec-lisp · **KEC status:** Gap · **Applicability:** Adapt

### Public/private API split; tagged-value `cond` dispatch
- **Where:** pp. 137–143
- **Insight:** A private `crossword--set` (double-hyphen = internal) does the raw write; public setters enforce the NYT 180°-symmetry invariant. Cells are tagged values (`nil`/`'letter`/`'block`/number); `crossword-insert-cell` dispatches with `cond` + a `t` catch-all.
- **Why it matters (KEC):** The `foo`/`foo--internal` convention mirrors KEC's `core/`-over-`kernel/` and NoshAPI's privileged-vs-cart tiers — a free discipline. `cond`/symbols/`nil`/dotted-pair coords are Have. Mismatch: elisp stores letters as ASCII *integers*; KEC numbers are float and there's no char type (fine within ±2²⁴, but no char ergonomics).
- **Goal:** both · **KEC status:** Have (`cond`/symbols/pairs) · **Applicability:** Direct

### Cursor ↔ data coordinate mapping; targeted redraw
- **Where:** pp. 143–145, 178–179
- **Insight:** Two inverse functions bridge point and (row,col), using `goto-char`/`forward-line`/`current-column` and integer division `(/ (current-column) 2)`. Redraw only the changed cell (+ its cousin), not the whole grid; later parameterized by optional `row`/`column`.
- **Why it matters (KEC):** Every text-UI interaction needs this bidirectional map; the nav primitives are firmware FFI. **Integer division gotcha:** KEC's `/` is float — carts must `floor` explicitly to mimic elisp `(/ x 2)`. Minimal-diff repaint is essential on the slow, arena-bounded renderer; bake "compute affected cells, redraw only those" into the knEmacs redraw contract.
- **Goal:** knEmacs · **KEC status:** N-A (nav firmware); Partial (float division) · **Applicability:** Adapt

### Lock the keymap; detect unsanctioned edits with a change hook + authorization flag
- **Where:** pp. 151–159
- **Insight:** Protect the structured buffer: `suppress-keymap`, `substitute-key-definition` (inherit the user's motion bindings), and the nuclear `(define-key map [t] 'undefined)` catch-all (later removed, too restrictive). Even so, a buffer-local `crossword-changes-authorized` flag + a `crossword-authorize` *macro* (binds it `t` around sanctioned mutations) + an `after-change-functions` watcher flag any change made while unauthorized.
- **Why it matters (KEC):** The read-only/protected-region pattern central to any buffer-owning app. The keymap-as-data lookup is plain KEC (alists, Have); the `crossword-authorize` body-wrapping macro is pure KEC (`mac` + quasiquote, Have). The change hook it cooperates with is firmware.
- **Goal:** both · **KEC status:** Partial (macro + alist Have; change hooks firmware) · **Applicability:** Adapt

### Reconcile once per command via `post-command-hook`; recover by re-parsing
- **Where:** pp. 159–164
- **Insight:** One command fires many `after-change` events, so recovery defers to `post-command-hook` (once per command), trusting the *buffer* over the model so the user's `undo` is respected — re-running `crossword-parse-buffer`, falling back to redraw, wrapped in nested `condition-case`.
- **Why it matters (KEC):** Two transfers: (1) **batch expensive reconciliation to a command boundary**, not per-event — the arena/GC-friendly pattern for the single-threaded runtime; (2) robust recovery needs `condition-case` — now Have (`core/36-recover`, ADR-0001). The buffer parser's list-build idiom (`cons` in a loop, `reverse` at the end) is Have and GC-safe; but it leans on `looking-at` (regex — Gap) and buffer-scan FFI.
- **Goal:** both · **KEC status:** Partial (list-build + `condition-case` Have; regex Gap; hooks firmware) · **Applicability:** Adapt

### Delegate heavy search across the FFI seam (don't port the subprocess)
- **Where:** pp. 163–177
- **Insight:** The word-finder builds a regexp string cell-by-cell and shells out to `egrep` via `call-process`, then upgrades to async `start-process` with filter/sentinel callbacks to stay responsive, stashing continuation state in buffer-locals.
- **Why it matters (KEC):** The device has no UNIX process model and no on-board `grep`/regex — so **Avoid** the mechanism. Port the *idea*: register a firmware dictionary/match primitive via `kec_bind_fe` and call it. The filter/sentinel **callback** pattern (don't block; register continuations) is the right model for long-running async work on the single-threaded, event-driven runtime — KEC's first-class lambdas (Have) express the callbacks; the async driver is firmware.
- **Goal:** knEmacs · **KEC status:** Gap (regex/subprocess); Have (callbacks) · **Applicability:** Avoid (mechanism) / Adapt (FFI-delegation idea)

### `this-command-keys`; the "know when to stop" thesis
- **Where:** pp. 145–148, 183
- **Insight:** `crossword-self-insert` reads its triggering key via `(aref (this-command-keys) 0)` so one command serves all 26 letters. The "Last Word" closes: there's no limit to how far you can take Crossword mode — or Emacs.
- **Why it matters (KEC):** knEmacs needs a `this-command-keys` equivalent (what key invoked me?) early — context-polymorphic dispatch is already a KN-86 concern (ADR-0016). The framing: knEmacs is a platform whose ceiling is set by the primitives the substrate exposes — ship the substrate, let carts go arbitrarily far.
- **Goal:** all · **KEC status:** N-A (firmware) · **Applicability:** Adapt

## Conclusion (book pp. 183–184)

### Emacs as toolkit; the deliberately-skipped roadmap
- **Where:** p. 184
- **Insight:** The book intentionally skipped **text properties**, overlays, timers, `apply`/`funcall`, custom mode lines, and the undo machinery — its goal was to teach *"what kinds of things are possible in Emacs Lisp and what they tend to look like."* It flags **text properties** (associate colors/actions/styled glyphs with buffer text) as the biggest uncovered facility. *"We learn by doing. Happy hacking."*
- **Why it matters (KEC):** Treat the skipped list as a **roadmap of substrate features a richer knEmacs will eventually pressure the KEC/firmware boundary to provide** — text properties (protected regions, styled glyphs, clickable text), overlays, timers, undo — beyond the keymap/change-hook basics this book exercises.
- **Goal:** all · **KEC status:** Gap (text properties/overlays/timers/undo) · **Applicability:** Aspirational

## Appendix A — Lisp Quick Reference (book pp. 185–194)

The compact recap of Lisp syntax — Basics, Data Types, Control Structures, Code
Objects. The best single source for the at-a-glance gap analysis above; the
notable per-construct findings:

- **Matches (Have):** `nil`=false=empty-list, `0`/`""` truthy; case-sensitive symbols; the full list roster (`car`/`cdr`/`cons`/`list`/`nth`/`nthcdr`/`append`/`reverse`/`length`) — iterative, GC-safe; symbol *property operations* (`put`/`get` on plist data); `if`/`cond`/`and`/`or`/`not`/`while`; **`when`/`unless`/`dotimes`/`dolist`/`case`/`let*`** (all in `core/40-ctrl`); **`prog1`** (`core/55-util`); **error recovery `unwind-protect`/`condition-case`/`ignore-errors` + full `macroexpand`** (`core/36-recover`, over the `try`/`raise` catch seam); quasiquote + `quote`; `lambda`/`defun`(`fn`/`defn`)/`defmacro`(`mac`)/`macroexpand-1`; `eval`/`apply`/`read-string`; `provide`/`require` feature registry; string `concat`/`length`/`substring`/indexed read; `format`.
- **Divergences (Partial):** `t` is a truthy symbol, not a reserved boolean type; **numbers are float-only** (no `integerp` type test; exact ≤ ±2²⁴); **chars are numbers** (no `?a` reader; use `char->string`/`string-ref`); assignment is **`set`** (top-level `let` binds globally); KEC is **Lisp-1** (one binding cell, no Lisp-2 function/value split); `put`/`get` are plist-data, not symbol-attached.
- **Gaps:** **vectors** (`vector`/`aref`/`aset`/`vectorp`) and the array/sequence layer that depends on them (`arrayp`/`sequencep`/`copy-sequence`); in-place string mutation (`aset` on strings). *(`prog1` and full `macroexpand` were gaps in the first pass; both shipped in ADR-0001.)*

The construct map condenses into the [gap-analysis tables](#the-kec-lisp-gap-analysis) above.

## Appendix B — Debugging and Profiling (book pp. 195–199)

Emacs's testing/debugging tools. KEC has none of the debugger/profiler tooling
today (only `kec test` with `deftest`/`check`/`check-err`, plus `eval`) — but the
appendix is the blueprint for an eventual on-device story, most of it
authorable *in KEC* on the reflective surface.

### Interactive evaluation is the cheap, direct win
- **Where:** pp. 195–196
- **Insight:** `eval-last-sexp` (`C-x C-e`), `eval-expression` (`M-:`), `eval-region`/`eval-current-buffer`, and the `*scratch*` `eval-print-last-sexp` (`C-j`, inserts the result inline).
- **Why it matters (KEC):** The most directly transferable item. On KEC's `eval` + `read-string` + error recovery, the `eval-last-sexp`/`eval-defun`/`*scratch*`-inline-eval trio is the right first knEmacs debugging affordance for an 80×25 amber terminal.
- **Goal:** both · **KEC status:** Have (`eval`/`read-string`; buffer-eval commands firmware) · **Applicability:** Direct

### Debugger, Edebug, ELP — and the meta-lesson
- **Where:** pp. 196–199
- **Insight:** A built-in debugger (`debug-on-error`, a `*Backtrace*` window, step commands), **Edebug** (a source-level instrumenting stepper written *entirely in Lisp*), and **ELP** (a profiler that instruments by name prefix). Both heavyweight tools work by *instrumenting code at the language level* — possible only because Elisp exposes eval, code-as-data, and function-binding mutation to itself.
- **Why it matters (KEC):** The roadmap guidance: invest in keeping KEC's **reflective surface complete** (`eval`/`macroexpand-1`/`globals`/`fn-params`/`bound?` — all Have) rather than building debug/profile features into the frozen kernel. A backtrace-on-error + frame-eval debugger, then Edebug-/ELP-style instrumentation, can be authored *in KEC* and stay arena-safe. The one prerequisite to verify is **mutable function bindings** (rebind a symbol's function to a wrapper) — the keystone for instrumentation (and for the `advice` facility, Ch 2).
- **Goal:** both · **KEC status:** Gap (tools); Have (reflective substrate); verify (function-binding rebind) · **Applicability:** Aspirational

## Appendices C & D — Sharing Code; Obtaining and Building Emacs (book pp. 200–206)

Largely N-A to KEC's toolchain (git repo + Starlight docs site + CMake/CTest, not
shar/newsgroup/autotools). Two faint echoes worth one line each:

- **Docstrings** (App C p. 201): Emacs's self-documentation rests on liberal in-function docstrings powering `describe-function`/`apropos`. KEC's docs *site* covers the "manual" leg; the missing leg is a **machine-readable, in-language docstring convention** for an on-device help system (Partial/Gap — pairs with the `apropos` note in Ch 1). Texinfo→Info is the spiritual ancestor of KEC's `docs/`→`website/` Starlight site.
- **`make check`** (App D): the only echo is KEC's `ctest`/`kec test` self-test step. Nothing actionable.
- **Goal:** kec-lisp · **KEC status:** N-A (bundling/build); Partial (docstrings) · **Applicability:** Avoid (mostly) / Adapt (docstrings)

---

## What to skip (out of scope for knEmacs / the language)

Not mined further: the FTP/`shar` examples (Preface, App C–D), GNU build mechanics
(App D), newsgroup-posting etiquette (App C), and the synchronous/asynchronous
**subprocess** machinery (Ch 10 word-finder) — the KN-86 has no UNIX process model;
delegate heavy work to a firmware FFI primitive instead. Byte-compilation (Ch 5) is
deliberately absent (Fe is a tree-walking interpreter; `kec build` is a source
bundler). Mouse/menu commands (Ch 10) are N-A (no mouse).

---

## Recommendations — prioritized KEC stdlib / knEmacs work

Derived from the gap analysis. The actionable answer to "what to add so KEC Lisp
can host knEmacs."

**Language / kernel (the few real holes):**
1. ~~**Lisp-level error recovery**~~ — **DONE (ADR-0001, `core/36-recover`).** `condition-case`, `unwind-protect`, `ignore-errors` shipped as Core macros over the existing `try`/`raise` catch seam (`core/35-error` is the raise side) — the first-pass "needs kernel/interpreter support" call was wrong. *Unblocked the command loop, the REPL, and every `save-*` wrapper.*
2. **Vectors** — `vector`/`make-vector`/`aref`/`aset`/`vectorp` in `host/` (C-backed, fixed-size, arena-friendly). *Unblocks efficient keymaps/char-tables, the cell grid, and rings.* **Now the highest-priority real hole** (deferred to a follow-up ADR — backing-memory/key-equality design).
3. ~~**Trivial Core adds**~~ — **DONE (ADR-0001):** `prog1` (`core/55-util`), full `macroexpand` (`core/36-recover`), `defvar` (`core/55-util`). *(Also landed in the same sprint: bitwise host primitives, a seedable RNG, and a string/char toolkit.)*
4. **Verify, then document** — `mac`/`fn` rest-arg + `&optional` surface; that `around`-style wrappers capture the original binding in a closure; whether a symbol's function binding is mutably rebindable (the keystone for `advice` and Edebug-/ELP-style tooling).
5. **Deferred-by-design** — a constrained **regex** subset in `host/` (anchors + classes + `*`/`+`/`?`, no backrefs) + mandatory `regexp-quote`; **`autoload`/`eval-after-load`** lazy load atop the existing `provide`/`require` registry; a `format-time-string` over the existing `clock`; container types (vectors/hash tables) per item 2.

**knEmacs (firmware over KEC, bound via `kec_bind_fe`) — build order:**
1. **Buffer + point + marker** object types (markers accept-int-or-marker; reuse/detach discipline).
2. **Command layer** — tag functions as commands; the `this-command`/`last-command` two-phase loop; `interactive` arg harvesting (code-letter *and* evaluated-thunk forms via `apply`); a `this-command-keys` equivalent.
3. **Keymaps as nested alists** (sparse-by-default) + `define-key`/`local-set-key`/`copy-keymap`, with layered minor→local→global precedence (ADR-0016).
4. **Modes** — buffer-local variables; `define-minor-mode`/`define-derived-mode` macros authored *in KEC*; `run-hooks`/`add-hook`.
5. **Change/command hooks** + reconcile-at-command-boundary discipline; narrowing.
6. **Reflective tooling in KEC** — `apropos`/`describe-*` over `globals`/`fn-params`; an `eval-last-sexp`/`*scratch*` REPL surface; later a backtrace-on-error debugger.
7. **Syntax tables** (`char-syntax`/`skip-syntax-forward`) for sexp/word motion — the Lisp-editor core.

**Cross-cutting language deltas to surface in knEmacs/kec-mode authoring docs:**
`set` not `setq`; float-only numbers (`floor` for integer division); `=`/`is` are
identity on pairs (use `equal?`); Lisp-1; top-level `let` binds globally; `nil`/`t`
truth model is *identical* (the one place elisp and KEC agree exactly).

---

*Compiled from a full read of Bob Glickstein's* Writing GNU Emacs Extensions
*(O'Reilly, 1997): Chapters 1–10, the Conclusion, and Appendices A–D. KEC-status
verdicts verified against `kernel/`, `core/`, `host/`, and `runtime/kec.c` on
2026-06-21. Page citations are to the printed book. Companion to the
[GNU Emacs Manual field notes](field-notes-emacs.md) (the user-facing editor model)
and the [AMOP field notes](field-notes-amop.md) (open-implementation / protocol
design), and the runnable [rxi/lite reference implementation](field-notes-rxi-lite.md)
(the thin-core-scripted-editor skeleton). Editor name: **knEmacs** (formerly nEmacs);
the Manual notes and the ADRs still use the older spelling pending a project-wide
rename.*
