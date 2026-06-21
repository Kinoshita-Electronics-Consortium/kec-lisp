# kec-lisp-mode

A GNU Emacs major mode for editing **KEC Lisp** (`.lsp`) — the scripting
language of the KN-86 handheld. Requires Emacs 27.1+.

> KEC Lisp reminder: assignment is `set`; `=` means equality. The mode
> highlights and indents accordingly.

## Features

| Capability | What you get |
|---|---|
| **File detection** | `.lsp` files open in `kec-lisp-mode`. It claims `.lsp` explicitly (Emacs otherwise defaults those to `lisp-mode`); a file-local `-*- mode: kec-lisp -*-` cookie always wins. |
| **Syntax highlighting** | Special forms (`set`, `fn`, `mac`, `when`, `cond`, `let*`, …), defining forms and the names they introduce, built-in functions, `:keyword`s, `nil`/`t`, and quote/quasiquote prefixes. |
| **Indentation** | KEC-aware: `fn`/`mac` bodies, `defn`, `cond`/`case`, `let*`/`letrec`, `dotimes`/`dolist`. (KEC's `let` is `(let NAME VAL)`, not a binding list, so it indents like a call.) |
| **Flymake** | A precise, local **structural** (paren-balance) check that pinpoints the offending delimiter, plus an optional `kec build` parse-check subprocess. |
| **Completion** ("IntelliSense") | `completion-at-point` over the KEC standard library, names defined in the current buffer, and the symbols actually bound in a running interpreter. |
| **Inferior REPL** | `M-x run-kec` starts `kec repl` under comint; send the last sexp / defun / region / buffer to it. |

## Install

The mode shells out to the `kec` CLI for Flymake and the REPL, so build it first
(`cmake -S . -B build && cmake --build build`) and put `build/kec` on your
`PATH`, or set `kec-lisp-program` to its absolute path.

Manual:

```elisp
(add-to-list 'load-path "/path/to/kec-lisp/editors/emacs")
(require 'kec-lisp-mode)
```

`use-package` (with a local checkout):

```elisp
(use-package kec-lisp-mode
  :load-path "/path/to/kec-lisp/editors/emacs"
  :mode "\\.lsp\\'"
  :custom (kec-lisp-program "/path/to/kec-lisp/build/kec"))
```

If you have other (Common Lisp) `.lsp` files you don't want claimed, drop the
`:mode`/`auto-mode-alist` entry and select the mode per-file with the
`-*- mode: kec-lisp -*-` cookie or `M-x kec-lisp-mode`.

## Key bindings

| Key | Command |
|---|---|
| `C-c C-z` | `run-kec` — start/raise the inferior REPL |
| `C-x C-e` | `kec-lisp-eval-last-sexp` |
| `C-M-x`   | `kec-lisp-eval-defun` |
| `C-c C-r` | `kec-lisp-eval-region` |
| `C-c C-b` | `kec-lisp-eval-buffer` |
| `C-c C-v` | `kec-lisp-check-parens` |

Structural sexp motion/editing (`C-M-f`, `C-M-b`, `C-M-u`, `C-M-d`,
`transpose-sexps`, `mark-sexp`, …) come from the syntax table, as in any Lisp
mode.

## Completion against the live language

Out of the box, completion offers the baked-in standard library plus names you
define in the buffer. To refresh the candidate set from the interpreter you
actually have installed (so new builtins show up), run:

```
M-x kec-lisp-refresh-symbols
```

It calls `kec eval "(globals)"` and folds the result into completion.

## Flymake notes

The KEC CLI reports parse errors **without a line/column**, so:

- The **structural** backend (always on) uses Emacs's own sexp scanner and
  pinpoints unbalanced delimiters precisely — this is the editor-side
  `check-parens` the KEC docs recommend before `kec build`.
- The **`kec build`** backend (toggle with `kec-lisp-flymake-use-kec`) catches
  non-paren parse errors, but attaches the diagnostic to the first line since
  the CLI gives no position. It parse-checks via `kec build … -o /dev/null`,
  which also inlines top-level `(load "…")` forms — an unresolvable load shows
  up as a (buffer-level) error.

## Running the tests

```sh
emacs -Q --batch -L . -l kec-lisp-mode.el -l kec-lisp-mode-tests.el \
      -f ert-run-tests-batch-and-exit
```

The two `kec build` integration tests skip automatically if `kec` is not on
`PATH`; the rest are pure Emacs and always run.
