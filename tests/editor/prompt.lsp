;; KEC Lisp editor tier — structural REPL prompt (:repl-prompt) conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/50-keymap.lsp")
(load "editor/60-persist.lsp")
(load "editor/90-repl.lsp")
(load "editor/92-prompt.lsp")

(deftest "prompt/eval-submits-current-form-and-resets"
  (let r (make-repl 16 40 nil))
  (let ps (make-prompt-session r))
  (buffer-reload! (prompt-buffer ps) "(+ 1 2)")        ; compose a form
  (mode-dispatch MODE-REPL-PROMPT 'EVAL ':tap ps)      ; EVAL submits
  (check (is (repl-count r) 1))
  (check (= (entry-output (car (repl-history r))) "3"))
  (check (equal? (buffer-forms (prompt-buffer ps)) (read-all "()"))))  ; prompt reset

(deftest "prompt/nav-edits-the-prompt-buffer"
  (let r (make-repl 16 40 nil))
  (let ps (make-prompt-session r))
  (buffer-reload! (prompt-buffer ps) "(a b c)")
  (mode-dispatch MODE-REPL-PROMPT 'CAR ':tap ps)       ; descend into the form
  (check (is (buffer-focus (prompt-buffer ps)) 'a))
  (mode-dispatch MODE-REPL-PROMPT 'CDR ':tap ps)       ; next sibling
  (check (is (buffer-focus (prompt-buffer ps)) 'b)))

(deftest "prompt/registered-in-mode-list"
  (check (not (nil? (keymap-mode MODE-REPL-PROMPT)))))
