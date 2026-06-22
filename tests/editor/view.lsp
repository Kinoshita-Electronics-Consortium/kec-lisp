;; KEC Lisp editor tier — view-model conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/40-view.lsp")

(defn mkbuf (name s) (make-buffer name (read-all s)))

;; a view node is (label . children)
(defn vlabel (n) (car n))
(defn vchildren (n) (cdr n))

(deftest "view/form->view-shape"
  (let n (form->view (read-string "(a b)")))
  (check (= (vlabel n) "(a b)"))            ; list node labelled by a preview
  (check (is (length (vchildren n)) 2))     ; two children
  (let a (nth (vchildren n) 0))
  (check (= (vlabel a) "a"))                ; leaf
  (check (nil? (vchildren a))))

(deftest "view/root-labelled-by-name"
  (let b (mkbuf "main" "(a) (b) (c)"))
  (let v (buffer->view b))
  (let root (car v))
  (check (= (vlabel root) "main"))          ; synthetic root = buffer name
  (check (is (length (vchildren root)) 3))) ; three top-level forms

(deftest "view/cursor-node-tracks-focus"
  (let b (mkbuf "s" "(a b c)"))
  (buffer-descend! b)                       ; focus = a
  (buffer-next! b)                          ; focus = b
  (let v (buffer->view b))
  (let cursor (cdr v))
  (check (= (vlabel cursor) "b"))           ; cursor view node is the b leaf
  (check (nil? (vchildren cursor))))

(deftest "view/cursor-node-on-list"
  (let b (mkbuf "s" "(a (b c) d)"))
  (buffer-descend! b)                       ; a
  (buffer-next! b)                          ; (b c)
  (let cursor (cdr (buffer->view b)))
  (check (= (vlabel cursor) "(b c)"))
  (check (is (length (vchildren cursor)) 2)))

(deftest "view/label-truncates-long-forms"
  (let n (form->view (read-string "(this is a fairly long form that exceeds the cap)")))
  (check (<= (string-length (vlabel n)) VIEW-LABEL-MAX))
  (check (string-suffix? (vlabel n) "...")))

(deftest "view/modeline"
  (let b (mkbuf "draft" "(a)"))
  (check (= (buffer-modeline b) "draft"))           ; clean
  (buffer-descend! b)
  (buffer-insert-leaf! b 'b)
  (check (= (buffer-modeline b) "draft *")))         ; modified marker

(deftest "view/echo-reports-focus-kind"
  (let b (mkbuf "s" "(a (b) c)"))
  (buffer-descend! b)                       ; a (a symbol) at depth 1
  (check (string-prefix? (buffer-echo b) ":symbol"))
  (buffer-next! b)                          ; (b) a list
  (check (string-prefix? (buffer-echo b) ":list")))

(deftest "view/completion-signature"
  ;; a Lisp fn bound in this context shows its arglist
  (defn demo-fn (alpha beta) (+ alpha beta))
  (check (= (completion-signature "demo-fn") "demo-fn (alpha beta)"))
  ;; an unbound name -> nil
  (check (nil? (completion-signature "no-such-symbol-xyz")))
  ;; a builtin (bound, but fn-params is nil for a primitive) -> nil
  (check (nil? (completion-signature "car"))))
