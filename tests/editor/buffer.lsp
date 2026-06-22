;; KEC Lisp editor tier — buffer-record conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")

(defn mkbuf (name s) (make-buffer name (read-all s)))

(deftest "buffer/construct"
  (let b (mkbuf "scratch" "(a b c)"))
  (check (= (buffer-name b) "scratch"))
  (check (not (buffer-modified? b)))
  (check (nil? (buffer-clipboard b)))
  (check (equal? (buffer-forms b) (read-all "(a b c)")))
  (check (equal? (buffer-focus b) (read-string "(a b c)"))))   ; seated on first form

(deftest "buffer/nav-does-not-modify"
  (let b (mkbuf "s" "(a b c)"))
  (buffer-descend! b)                       ; on a
  (check (is (buffer-focus b) 'a))
  (buffer-next! b)                          ; on b
  (check (is (buffer-focus b) 'b))
  (check (not (buffer-modified? b))))        ; navigation is not an edit

(deftest "buffer/insert-marks-modified"
  (let b (mkbuf "s" "(a c)"))
  (buffer-descend! b)                       ; on a
  (buffer-insert-leaf! b 'b)                ; (a b c)
  (check (buffer-modified? b))
  (check (equal? (buffer-forms b) (read-all "(a b c)"))))

(deftest "buffer/delete-cuts-to-clipboard"
  (let b (mkbuf "s" "(a b c)"))
  (buffer-descend! b)                       ; on a
  (buffer-next! b)                          ; on b
  (buffer-delete! b)                        ; cut b
  (check (is (buffer-clipboard b) 'b))      ; clipboard holds the cut
  (check (equal? (buffer-forms b) (read-all "(a c)")))
  (check (buffer-modified? b)))

(deftest "buffer/paste-uses-clipboard"
  (let b (mkbuf "s" "(a b c)"))
  (buffer-descend! b)                       ; on a
  (buffer-next! b)                          ; on b
  (buffer-delete! b)                        ; cut b -> (a c), on c, clip=b
  (buffer-paste! b)                         ; paste b after c -> (a c b), on b
  (check (is (buffer-focus b) 'b))
  (check (equal? (buffer-forms b) (read-all "(a c b)"))))

(deftest "buffer/paste-empty-clipboard-is-noop"
  (let b (mkbuf "s" "(a b)"))
  (buffer-descend! b)
  (buffer-paste! b)                         ; clipboard empty -> no change
  (check (equal? (buffer-forms b) (read-all "(a b)"))))

(deftest "buffer/undo-restores"
  (let b (mkbuf "s" "(a b c)"))
  (buffer-descend! b)                       ; on a
  (check (not (buffer-can-undo? b)))
  (buffer-insert-leaf! b 'z)               ; (a z b c)
  (check (equal? (buffer-forms b) (read-all "(a z b c)")))
  (check (buffer-can-undo? b))
  (buffer-undo! b)                          ; back to (a b c)
  (check (equal? (buffer-forms b) (read-all "(a b c)")))
  (check (not (buffer-can-undo? b))))

(deftest "buffer/undo-multiple-edits"
  (let b (mkbuf "s" "(a)"))
  (buffer-descend! b)                       ; on a
  (buffer-insert-leaf! b 'b)               ; (a b)
  (buffer-insert-leaf! b 'c)               ; (a b c)  (cursor on b after first insert? on b then insert c after b)
  (check (equal? (buffer-forms b) (read-all "(a b c)")))
  (buffer-undo! b)                          ; undo c
  (check (equal? (buffer-forms b) (read-all "(a b)")))
  (buffer-undo! b)                          ; undo b
  (check (equal? (buffer-forms b) (read-all "(a)"))))

(deftest "buffer/literal-entry-commit"
  (let b (mkbuf "s" "(a c)"))
  (buffer-descend! b)                       ; on a
  (check (not (buffer-in-literal? b)))
  (buffer-enter-literal! b)
  (check (buffer-in-literal? b))
  (buffer-literal-push! b "b")              ; type "b"
  (buffer-literal-push! b "1")              ; -> "b1"
  (check (= (buffer-literal-text b) "b1"))
  (buffer-literal-backspace! b)             ; -> "b"
  (check (= (buffer-literal-text b) "b"))
  (buffer-commit-literal! b)                ; insert b after a
  (check (not (buffer-in-literal? b)))
  (check (equal? (buffer-forms b) (read-all "(a b c)"))))

(deftest "buffer/literal-entry-cancel"
  (let b (mkbuf "s" "(a c)"))
  (buffer-descend! b)
  (buffer-enter-literal! b)
  (buffer-literal-push! b "zzz")
  (buffer-cancel-literal! b)                ; discard
  (check (not (buffer-in-literal? b)))
  (check (equal? (buffer-forms b) (read-all "(a c)"))))  ; unchanged

(deftest "buffer/literal-commit-a-list"
  (let b (mkbuf "s" "(a c)"))
  (buffer-descend! b)
  (buffer-enter-literal! b)
  (buffer-literal-push! b "(x y)")          ; a whole form
  (buffer-commit-literal! b)
  (check (equal? (buffer-forms b) (read-all "(a (x y) c)"))))

(deftest "buffer/current-form"
  (let b (mkbuf "s" "(foo (bar baz)) (other)"))
  (buffer-descend! b)                       ; foo
  (buffer-next! b)                          ; (bar baz)
  (buffer-descend! b)                       ; bar
  ;; the current TOP-LEVEL form is the whole first form, regardless of depth
  (check (equal? (buffer-current-form b) (read-string "(foo (bar baz))"))))
