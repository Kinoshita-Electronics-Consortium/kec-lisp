;; KEC Lisp editor tier — persistence (serialize/load) conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/60-persist.lsp")

(defn mkbuf (name s) (make-buffer name (read-all s)))

(deftest "persist/empty-buffer-serializes-to-parens"
  (let b (make-buffer "empty" nil))
  (check (= (buffer->string b) "()")))

(deftest "persist/serialize-nonempty"
  (let b (mkbuf "s" "(a b c)"))
  (check (= (buffer->string b) "(a b c)")))

(deftest "persist/roundtrip-preserves-shape"
  (let src "(define (f x) (+ x 1))\n(foo (bar baz))")
  (let b (buffer-load "round" src))
  (let b2 (buffer-load "round2" (buffer->string b)))
  (check (equal? (buffer-forms b) (buffer-forms b2)))     ; structural identity
  (check (equal? (buffer-forms b) (read-all src))))

(deftest "persist/load-resets-cursor-to-root"
  (let b (buffer-load "s" "(a b) (c d)"))
  (check (equal? (buffer-focus b) (read-string "(a b)")))  ; seated on first form
  (check (not (buffer-modified? b))))

(deftest "persist/serialize-byte-cap"
  (let b (mkbuf "s" "(a b c)"))
  (check (= (buffer-serialize b 100) "(a b c)"))           ; within cap
  (check (is (buffer-serialize b 3) 0)))                   ; overflow -> 0

(deftest "persist/reload-replaces-root"
  (let b (mkbuf "s" "(a b c)"))
  (buffer-descend! b)
  (buffer-insert-leaf! b 'z)                               ; modify it
  (check (buffer-modified? b))
  (buffer-reload! b "(x y)")                               ; reload from text
  (check (equal? (buffer-forms b) (read-all "(x y)")))
  (check (equal? (buffer-focus b) (read-string "(x y)")))  ; cursor reset
  (check (not (buffer-modified? b)))                       ; modified cleared
  (check (nil? (buffer-clipboard b))))                     ; clipboard cleared
