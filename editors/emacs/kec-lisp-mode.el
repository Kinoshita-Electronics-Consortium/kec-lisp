;;; kec-lisp-mode.el --- Major mode for KEC Lisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kinoshita Electronics Consortium

;; Author: Kinoshita Electronics Consortium
;; Maintainer: KEC Lisp authors
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: languages, lisp
;; URL: https://github.com/Kinoshita-Electronics-Consortium/kec-lisp

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A major mode for editing KEC Lisp (`.lsp') source — the scripting language
;; of the KN-86 handheld.  KEC Lisp is a small Fe-based Lisp; the most important
;; thing to remember is that *assignment is `set', and `=' means equality*.
;;
;; What this mode gives you:
;;
;; - File detection: `.lsp' files open in `kec-lisp-mode' (it claims `.lsp'
;;   explicitly, since Emacs otherwise defaults those to `lisp-mode'); a
;;   file-local `-*- mode: kec-lisp -*-' cookie always wins.
;; - Syntax highlighting (font-lock): special forms, control macros, defining
;;   forms and the names they introduce, built-in functions, `:keyword's,
;;   `nil'/`t', and quote/quasiquote prefixes.
;; - Indentation aware of KEC's forms (`fn'/`mac' bodies, `defn', `cond'/`case',
;;   `let*'/`letrec', `dotimes'/`dolist').  Note KEC's `let' is `(let NAME VAL)',
;;   not a binding list, so it indents as a plain call.
;; - Flymake: a precise, local structural (paren-balance) check, plus an
;;   optional `kec build' parse-check subprocess.
;; - Completion-at-point ("IntelliSense"): the KEC standard library, names
;;   defined in the current buffer, and — after `M-x kec-lisp-refresh-symbols'
;;   or when an inferior REPL is live — the symbols actually bound in the running
;;   interpreter.
;; - An inferior `kec' REPL (`M-x run-kec') with eval commands to send the last
;;   sexp / defun / region / buffer to it.

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'flymake)
(require 'lisp-mode) ; for `lisp-indent-line'

;;;; Customization

(defgroup kec-lisp nil
  "Major mode for editing KEC Lisp."
  :group 'languages
  :prefix "kec-lisp-")

(defcustom kec-lisp-program "kec"
  "Program used to run KEC Lisp (the `kec' CLI).
Used for the inferior REPL, Flymake's parse-check, and live completion."
  :type 'string
  :group 'kec-lisp)

(defcustom kec-lisp-repl-arguments '("repl")
  "Command-line arguments passed to `kec-lisp-program' for the inferior REPL."
  :type '(repeat string)
  :group 'kec-lisp)

(defcustom kec-lisp-flymake-use-kec t
  "When non-nil, Flymake also runs `kec build' as a parse-check subprocess.
The KEC CLI reports parse errors without a line/column, so that diagnostic
is attached to the start of the buffer; the structural check (always on) is
what gives precise positions for unbalanced expressions."
  :type 'boolean
  :group 'kec-lisp)

;;;; Symbol knowledge

(defconst kec-lisp-special-forms
  '("set" "let" "if" "fn" "mac" "while" "quote" "and" "or" "do" "begin"
    "when" "unless" "cond" "case" "let*" "letrec" "dotimes" "dolist"
    "define" "defn" "defmacro" "quasiquote")
  "KEC special forms and defining/binding macros, highlighted as keywords.")

(defconst kec-lisp-constants '("nil" "t")
  "KEC constants.")

(defconst kec-lisp-standard-symbols
  '("*" "+" "-" "/" "/=" "<" "<=" "=" "==" ">" ">=" "abs" "and" "any?"
    "append" "append-file" "apply" "args" "assoc" "atom" "begin" "bound?"
    "car" "case" "cdr" "ceil" "char->string" "char-alpha?" "char-alphanumeric?"
    "char-digit?" "char-whitespace?" "clock" "cond" "cons" "count" "define"
    "defmacro" "defn" "do" "dolist" "dotimes" "drop" "equal?" "error"
    "error-message" "error?" "eval" "even?" "every?" "exit" "file-exists?"
    "filter" "find" "floor" "fn" "fn-params" "fn?" "fold-left" "fold-right"
    "for-each" "format" "gensym" "get" "get-prop" "getenv" "globals" "has?"
    "if" "is" "join" "keys" "last" "length" "let" "let*" "letrec" "list"
    "list-dir" "load" "mac" "macroexpand-1" "map" "max" "member" "merge" "min"
    "mod" "negative?" "newline" "nil?" "not" "nth" "number->string" "number?"
    "odd?" "or" "pair?" "positive?" "pow" "princ" "print" "provide" "provided?"
    "put" "put-prop" "quasiquote" "quote" "raise" "rand" "rand-int" "range"
    "read-all" "read-file" "read-string" "remove" "repr" "require" "reverse"
    "round" "set" "setcar" "setcdr" "sort" "split" "sqrt" "str" "string->number"
    "string->symbol" "string-append" "string-length" "string-ref"
    "string-search" "string?" "substring" "symbol->string" "symbol?" "t" "take"
    "try" "type-of" "unless" "values" "when" "while" "write-file" "zero?")
  "Every symbol KEC Core + the host stdlib bind, for completion and font-lock.
Refresh against your installed interpreter with `kec-lisp-refresh-symbols'.")

(defconst kec-lisp-builtins
  (cl-set-difference kec-lisp-standard-symbols
                     (append kec-lisp-special-forms kec-lisp-constants)
                     :test #'string=)
  "KEC built-in functions (standard symbols minus special forms and constants).")

(defvar kec-lisp--live-symbols nil
  "Symbols harvested from a running interpreter by `kec-lisp-refresh-symbols'.")

;;;; Syntax table

(defvar kec-lisp-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; Comments: ; to end of line.
    (modify-syntax-entry ?\; "<" st)
    (modify-syntax-entry ?\n ">" st)
    ;; Strings and the escape char.
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?\\ "\\" st)
    ;; Lists.
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    ;; Quote family — prefix characters.
    (modify-syntax-entry ?\' "'" st)
    (modify-syntax-entry ?\` "'" st)
    (modify-syntax-entry ?\, "'" st)
    (modify-syntax-entry ?@ "'" st)
    ;; KEC identifiers carry these as constituents: bound?, string->number,
    ;; char-alpha?, /=, <=, +, *, etc.  `:' too, since keywords (:error) are
    ;; ordinary symbols in KEC.
    (dolist (c '(?- ?_ ?+ ?* ?/ ?< ?> ?= ?? ?! ?% ?& ?~ ?^ ?$ ?. ?:))
      (modify-syntax-entry c "_" st))
    st)
  "Syntax table for `kec-lisp-mode'.")

;;;; Font lock

(defun kec-lisp--symbol-re (names)
  "Return a regexp matching any symbol in NAMES at symbol boundaries."
  (concat "\\_<" (regexp-opt names t) "\\_>"))

(defconst kec-lisp-font-lock-keywords
  (let ((sym "\\(?:\\sw\\|\\s_\\)+"))
    `( ;; Defining forms introduce a name.
      (,(concat "(\\(?:defn\\|defmacro\\)\\s-+\\(" sym "\\)")
       (1 font-lock-function-name-face))
      (,(concat "(define\\s-+(\\s-*\\(" sym "\\)")
       (1 font-lock-function-name-face))
      (,(concat "(define\\s-+\\(" sym "\\)")
       (1 font-lock-variable-name-face))
      (,(concat "(set\\s-+\\(" sym "\\)")
       (1 font-lock-variable-name-face))
      ;; Special forms / binding + control macros.
      (,(kec-lisp--symbol-re kec-lisp-special-forms) . font-lock-keyword-face)
      ;; nil / t.
      (,(kec-lisp--symbol-re kec-lisp-constants) . font-lock-constant-face)
      ;; Keyword symbols: :foo.
      (,(concat "\\_<:" sym) . font-lock-builtin-face)
      ;; Built-in functions.
      (,(kec-lisp--symbol-re kec-lisp-builtins) . font-lock-builtin-face))
    )
  "Font-lock highlighting for `kec-lisp-mode'.")

;;;; Indentation

(defvar kec-lisp-indent-rules
  '(("when" . 1) ("unless" . 1) ("while" . 1)
    ("let*" . 1) ("letrec" . 1) ("dotimes" . 1) ("dolist" . 1)
    ("case" . 1) ("cond" . 0) ("do" . 0) ("begin" . 0)
    ("fn" . 1) ("mac" . 1)
    ("defn" . 2) ("defmacro" . 2) ("define" . defun) ("if" . 2))
  "Alist of KEC form name -> indentation rule.
An integer N means N distinguished arguments, then a body indented by
`lisp-body-indent'.  The symbol `defun' means defun-style indentation.
KEC's `let' is deliberately absent: `(let NAME VAL)' is not a binding form,
so it indents like an ordinary call.")

(defun kec-lisp-indent-function (indent-point state)
  "Indent calls in `kec-lisp-mode', honoring `kec-lisp-indent-rules'.
INDENT-POINT and STATE are as for `lisp-indent-function'.  This mirrors the
stock indenter but resolves forms through KEC's own rule table instead of the
global `lisp-indent-function' symbol property (which would leak Emacs Lisp's
`let' semantics onto KEC's different `let')."
  (let ((normal-indent (current-column)))
    (goto-char (1+ (elt state 1)))
    (if (and (elt state 2)
             (not (looking-at "\\sw\\|\\s_")))
        ;; First element is not a symbol: align under it.
        (progn
          (unless (> (save-excursion (forward-line 1) (point)) (elt state 2))
            (goto-char (elt state 2)))
          (current-column))
      (let* ((fn-end (save-excursion (forward-sexp 1) (point)))
             (fn (buffer-substring-no-properties (point) fn-end))
             (method (cdr (assoc fn kec-lisp-indent-rules))))
        (cond
         ((eq method 'defun)
          (lisp-indent-defform state indent-point))
         ((integerp method)
          (lisp-indent-specform method state indent-point normal-indent))
         (t normal-indent))))))

;;;; Completion at point

(defun kec-lisp--buffer-definitions ()
  "Scan the current buffer for top-level names it defines."
  (let (names)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "(\\(?:defn\\|defmacro\\|set\\)\\s-+\\(\\(?:\\sw\\|\\s_\\)+\\)\\|\
(define\\s-+(?\\s-*\\(\\(?:\\sw\\|\\s_\\)+\\)"
              nil t)
        (push (or (match-string-no-properties 1)
                  (match-string-no-properties 2))
              names)))
    names))

(defun kec-lisp-completion-at-point ()
  "Completion-at-point for KEC symbols.
Candidates come from the standard library, names defined in this buffer, and
any symbols harvested from a live interpreter (`kec-lisp-refresh-symbols')."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (when bounds
      (list (car bounds) (cdr bounds)
            (completion-table-dynamic
             (lambda (_)
               (delete-dups
                (append (kec-lisp--buffer-definitions)
                        kec-lisp--live-symbols
                        kec-lisp-standard-symbols))))
            :annotation-function
            (lambda (cand)
              (cond ((member cand kec-lisp-special-forms) " special")
                    ((member cand kec-lisp-constants) " const")
                    ((member cand kec-lisp-standard-symbols) " stdlib")
                    (t " local")))
            :exclusive 'no))))

(defun kec-lisp-refresh-symbols ()
  "Harvest the symbols bound in the installed interpreter via `(globals)'.
Updates the live completion set so it reflects the actual `kec-lisp-program'."
  (interactive)
  (if (not (executable-find kec-lisp-program))
      (user-error "Cannot find `%s' on PATH" kec-lisp-program)
    (with-temp-buffer
      (if (zerop (call-process kec-lisp-program nil t nil "eval" "(globals)"))
          (let ((text (string-trim (buffer-string))))
            (setq kec-lisp--live-symbols
                  (split-string (string-trim text "(" ")") "[ \t\n]+" t))
            (when (called-interactively-p 'interactive)
              (message "kec-lisp: %d live symbols" (length kec-lisp--live-symbols))))
        (user-error "`%s eval' failed: %s" kec-lisp-program
                    (string-trim (buffer-string)))))))

;;;; Flymake — structural (precise) + optional kec parse-check (coarse)

(defun kec-lisp-flymake-structural (report-fn &rest _args)
  "Flymake backend: report unbalanced expressions with precise positions.
Uses Emacs's own sexp scanner, so it needs no subprocess and pinpoints the
offending delimiter — the editor-side equivalent of `check-parens' the KEC docs
recommend before `kec build'."
  (let (diags)
    (save-excursion
      (goto-char (point-min))
      (condition-case err
          (while (progn (skip-chars-forward " \t\n\r\f")
                        (not (eobp)))
            (forward-sexp 1))
        (scan-error
         (let* ((beg (or (nth 2 err) (point)))
                (end (or (nth 3 err) (min (point-max) (1+ beg)))))
           (push (flymake-make-diagnostic
                  (current-buffer) beg (max end (1+ beg)) :error
                  (or (nth 1 err) "Unbalanced expression"))
                 diags)))
        (error
         (push (flymake-make-diagnostic
                (current-buffer) (point-min) (min (point-max) (1+ (point-min)))
                :error (error-message-string err))
               diags))))
    (funcall report-fn diags)))

(defvar-local kec-lisp--flymake-proc nil)

(defun kec-lisp--flymake-clean-message (raw)
  "Tidy RAW `kec' stderr into a one-line diagnostic message."
  (let ((line (car (split-string (string-trim raw) "\n" t))))
    (replace-regexp-in-string "\\`kec\\(?: build\\)?: *" "" (or line "parse error"))))

(defun kec-lisp-flymake-kec (report-fn &rest _args)
  "Flymake backend: parse-check the buffer by running `kec build'.
KEC reports parse errors without a position, so the diagnostic is attached to
the first line; the structural backend supplies precise locations.  Honors
`kec-lisp-flymake-use-kec'."
  (when (and kec-lisp-flymake-use-kec
             (executable-find kec-lisp-program))
    (when (process-live-p kec-lisp--flymake-proc)
      (kill-process kec-lisp--flymake-proc))
    (let* ((src (current-buffer))
           (tmp (make-temp-file "kec-flymake" nil ".lsp" (buffer-string))))
      (setq
       kec-lisp--flymake-proc
       (make-process
        :name "kec-flymake" :noquery t :connection-type 'pipe
        :buffer (generate-new-buffer " *kec-flymake*")
        :command (list kec-lisp-program "build" tmp "-o" null-device)
        :sentinel
        (lambda (proc _event)
          (when (memq (process-status proc) '(exit signal))
            (unwind-protect
                (when (with-current-buffer src (eq proc kec-lisp--flymake-proc))
                  (let ((code (process-exit-status proc))
                        (out (with-current-buffer (process-buffer proc)
                               (buffer-string))))
                    (funcall
                     report-fn
                     (if (zerop code)
                         nil
                       (with-current-buffer src
                         (list (flymake-make-diagnostic
                                src (point-min)
                                (min (point-max)
                                     (save-excursion (goto-char (point-min))
                                                     (line-end-position)))
                                :error
                                (kec-lisp--flymake-clean-message out))))))))
              (ignore-errors (delete-file tmp))
              (kill-buffer (process-buffer proc))))))))))

;;;; Commands — the inferior REPL and eval

(define-derived-mode inferior-kec-mode comint-mode "Inferior KEC"
  "Major mode for the inferior KEC Lisp REPL."
  (setq-local comint-prompt-regexp "^kec> *")
  (setq-local comint-prompt-read-only t)
  (setq-local comint-input-ignoredups t)
  (setq-local mode-line-process '(":%s")))

;;;###autoload
(defun run-kec ()
  "Run an inferior KEC Lisp REPL in the `*kec*' buffer and switch to it."
  (interactive)
  (let ((buf (get-buffer-create "*kec*")))
    (unless (comint-check-proc buf)
      (apply #'make-comint-in-buffer "kec" buf
             kec-lisp-program nil kec-lisp-repl-arguments)
      (with-current-buffer buf (inferior-kec-mode)))
    (pop-to-buffer buf)
    buf))

(defun kec-lisp--process ()
  "Return the inferior KEC process, starting one if needed."
  (or (get-buffer-process "*kec*")
      (progn (save-window-excursion (run-kec))
             (get-buffer-process "*kec*"))))

(defun kec-lisp-eval-region (start end)
  "Send the region between START and END to the inferior KEC REPL."
  (interactive "r")
  (comint-send-string (kec-lisp--process)
                      (concat (buffer-substring-no-properties start end) "\n")))

(defun kec-lisp-eval-last-sexp ()
  "Send the sexp before point to the inferior KEC REPL."
  (interactive)
  (kec-lisp-eval-region (save-excursion (backward-sexp) (point)) (point)))

(defun kec-lisp-eval-defun ()
  "Send the top-level form around point to the inferior KEC REPL."
  (interactive)
  (save-excursion
    (let ((end (progn (end-of-defun) (point)))
          (beg (progn (beginning-of-defun) (point))))
      (kec-lisp-eval-region beg end))))

(defun kec-lisp-eval-buffer ()
  "Send the whole buffer to the inferior KEC REPL."
  (interactive)
  (kec-lisp-eval-region (point-min) (point-max)))

(defun kec-lisp-check-parens ()
  "Report the first unbalanced delimiter in the buffer, or that it is balanced."
  (interactive)
  (check-parens)
  (message "kec-lisp: parentheses balanced"))

;;;; Keymap

(defvar kec-lisp-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") #'run-kec)
    (define-key map (kbd "C-c C-r") #'kec-lisp-eval-region)
    (define-key map (kbd "C-c C-b") #'kec-lisp-eval-buffer)
    (define-key map (kbd "C-M-x")   #'kec-lisp-eval-defun)
    (define-key map (kbd "C-x C-e") #'kec-lisp-eval-last-sexp)
    (define-key map (kbd "C-c C-v") #'kec-lisp-check-parens)
    map)
  "Keymap for `kec-lisp-mode'.")

;;;; The mode

;;;###autoload
(define-derived-mode kec-lisp-mode prog-mode "KEC Lisp"
  "Major mode for editing KEC Lisp source.

\\{kec-lisp-mode-map}"
  :syntax-table kec-lisp-mode-syntax-table
  (setq-local comment-start "; ")
  (setq-local comment-end "")
  (setq-local comment-start-skip ";+[ \t]*")
  (setq-local comment-add 1)        ; M-; inserts ";;"
  (setq-local comment-column 40)
  (setq-local indent-tabs-mode nil)
  (setq-local open-paren-in-column-0-is-defun-start t)
  (setq-local font-lock-defaults '(kec-lisp-font-lock-keywords))
  (setq-local indent-line-function #'lisp-indent-line)
  (setq-local lisp-indent-function #'kec-lisp-indent-function)
  (setq-local parse-sexp-ignore-comments t)
  (setq-local electric-pair-skip-whitespace 'chomp)
  (add-hook 'completion-at-point-functions
            #'kec-lisp-completion-at-point nil t)
  (add-hook 'flymake-diagnostic-functions
            #'kec-lisp-flymake-structural nil t)
  (add-hook 'flymake-diagnostic-functions
            #'kec-lisp-flymake-kec nil t)
  (flymake-mode 1))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.lsp\\'" . kec-lisp-mode))

(provide 'kec-lisp-mode)
;;; kec-lisp-mode.el ends here
