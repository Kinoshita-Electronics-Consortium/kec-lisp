;;; kec-lisp-mode-tests.el --- ERT tests for kec-lisp-mode -*- lexical-binding: t; -*-

;; Run:
;;   emacs -Q --batch -l kec-lisp-mode.el -l kec-lisp-mode-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'kec-lisp-mode)

(defmacro kec-lisp-tests--with (text &rest body)
  "Run BODY in a `kec-lisp-mode' buffer containing TEXT, point at end."
  (declare (indent 1))
  `(with-temp-buffer
     (kec-lisp-mode)
     (insert ,text)
     ,@body))

;;;; File detection

(ert-deftest kec-lisp-test-auto-mode ()
  "`.lsp' files select `kec-lisp-mode'."
  (should (eq 'kec-lisp-mode
              (assoc-default "snake.lsp" auto-mode-alist #'string-match))))

(ert-deftest kec-lisp-test-file-local-cookie ()
  "A `-*- mode: kec-lisp -*-' cookie selects the mode."
  (with-temp-buffer
    (insert ";; -*- mode: kec-lisp -*-\n(set x 1)\n")
    (let ((buffer-file-name "/tmp/whatever.txt"))
      (set-auto-mode))
    (should (eq major-mode 'kec-lisp-mode))))

;;;; Syntax table

(ert-deftest kec-lisp-test-symbol-constituents ()
  "`?', `>', `-', `/' are symbol constituents (bound?, string->number)."
  (kec-lisp-tests--with "(bound? string->number)"
    (goto-char (point-min))
    (forward-char 1)                    ; past the (
    (forward-sexp 1)                    ; over the whole `bound?'
    (should (equal "bound?"
                   (buffer-substring-no-properties 2 (point))))))

(ert-deftest kec-lisp-test-comment-vars ()
  "Comment syntax is the Lisp single-semicolon convention."
  (kec-lisp-tests--with ""
    (should (equal "; " comment-start))
    (should (equal "" comment-end))
    (should-not indent-tabs-mode)))

;;;; Font lock

(defun kec-lisp-tests--face-at (needle text)
  "Fontify TEXT in `kec-lisp-mode' and return the face on NEEDLE's first char."
  (with-temp-buffer
    (kec-lisp-mode)
    (insert text)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward needle)
    (get-text-property (match-beginning 0) 'face)))

(ert-deftest kec-lisp-test-font-lock-special-form ()
  (should (eq 'font-lock-keyword-face
              (kec-lisp-tests--face-at "when" "(when x 1)"))))

(ert-deftest kec-lisp-test-font-lock-defn-name ()
  (should (eq 'font-lock-function-name-face
              (kec-lisp-tests--face-at "sq" "(defn sq (n) (* n n))"))))

(ert-deftest kec-lisp-test-font-lock-builtin ()
  (should (eq 'font-lock-builtin-face
              (kec-lisp-tests--face-at "map" "(map f xs)"))))

(ert-deftest kec-lisp-test-font-lock-constant ()
  (should (eq 'font-lock-constant-face
              (kec-lisp-tests--face-at "nil" "(set x nil)"))))

(ert-deftest kec-lisp-test-font-lock-keyword-symbol ()
  (should (eq 'font-lock-builtin-face
              (kec-lisp-tests--face-at ":error" "(cons :error m)"))))

;;;; Indentation

(defun kec-lisp-tests--reindent (text)
  "Return TEXT reindented by `kec-lisp-mode'."
  (with-temp-buffer
    (kec-lisp-mode)
    (insert text)
    (indent-region (point-min) (point-max))
    (buffer-string)))

(ert-deftest kec-lisp-test-indent-defn-body ()
  (should (equal "(defn sq (n)\n  (* n n))"
                 (kec-lisp-tests--reindent "(defn sq (n)\n(* n n))"))))

(ert-deftest kec-lisp-test-indent-when-body ()
  (should (equal "(when ready\n  (go)\n  (stop))"
                 (kec-lisp-tests--reindent "(when ready\n(go)\n(stop))"))))

(ert-deftest kec-lisp-test-indent-cond-clauses ()
  (should (equal "(cond\n  ((< n 0) 'neg)\n  (else 'pos))"
                 (kec-lisp-tests--reindent
                  "(cond\n((< n 0) 'neg)\n(else 'pos))"))))

;;;; Completion at point

(ert-deftest kec-lisp-test-completion-stdlib ()
  "Completing `ma' offers stdlib names like `map'/`max'/`mac'."
  (kec-lisp-tests--with "(ma"
    (let* ((capf (kec-lisp-completion-at-point))
           (table (nth 2 capf))
           (cands (all-completions "ma" table)))
      (should (member "map" cands))
      (should (member "max" cands))
      (should (member "mac" cands)))))

(ert-deftest kec-lisp-test-completion-buffer-defs ()
  "Names defined earlier in the buffer are completion candidates."
  (kec-lisp-tests--with "(defn my-helper (x) x)\n(my-h"
    (let* ((capf (kec-lisp-completion-at-point))
           (table (nth 2 capf))
           (cands (all-completions "my-h" table)))
      (should (member "my-helper" cands)))))

;;;; Flymake (structural)

(defun kec-lisp-tests--structural (text)
  "Return the structural Flymake diagnostics for TEXT."
  (with-temp-buffer
    (kec-lisp-mode)
    (insert text)
    (let (out)
      (kec-lisp-flymake-structural (lambda (diags &rest _) (setq out diags)))
      out)))

(ert-deftest kec-lisp-test-flymake-balanced ()
  "Balanced source yields no structural diagnostics."
  (should-not (kec-lisp-tests--structural "(defn ok (x) (+ x 1))\n")))

(ert-deftest kec-lisp-test-flymake-unbalanced ()
  "An unclosed list yields a diagnostic."
  (let ((diags (kec-lisp-tests--structural "(defn bad (y) (+ y\n")))
    (should (= 1 (length diags)))
    (should (eq :error (flymake-diagnostic-type (car diags))))))

(defun kec-lisp-tests--kec-diags (text)
  "Run the `kec build' Flymake backend on TEXT and wait for the result.
Skips the test if `kec-lisp-program' is not installed."
  (unless (executable-find kec-lisp-program)
    (ert-skip "kec not on PATH"))
  (with-temp-buffer
    (kec-lisp-mode)
    (insert text)
    (let ((done nil) (out nil))
      (kec-lisp-flymake-kec (lambda (d &rest _) (setq out d done t)))
      (let ((n 0))
        (while (and (not done) (< n 100))
          (accept-process-output nil 0.05)
          (setq n (1+ n))))
      (should done)
      out)))

(ert-deftest kec-lisp-test-flymake-kec-parse-error ()
  "The `kec build' backend reports a real parse error (needs `kec')."
  (let ((diags (kec-lisp-tests--kec-diags "(defn bad (y) (+ y\n")))
    (should (= 1 (length diags)))))

(ert-deftest kec-lisp-test-flymake-kec-clean ()
  "The `kec build' backend reports nothing for valid source (needs `kec')."
  (should-not (kec-lisp-tests--kec-diags "(defn ok (x) (+ x 1))\n")))

(provide 'kec-lisp-mode-tests)
;;; kec-lisp-mode-tests.el ends here
