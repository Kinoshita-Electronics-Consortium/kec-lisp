;; KEC Lisp — apply / read-string conformance (GWP-531).
;;
;; Both are language-level (available in every profile). apply calls a function
;; with the elements of a list; read-string parses the FIRST s-expression of a
;; string into a value — a reader, NOT eval (it must never execute the form).

(deftest "apply/builtin"
  (check (is (apply + (list 1 2 3)) 6))
  (check (is (apply * (list 2 3 4)) 24)))

(deftest "apply/empty-arglist"
  ;; apply with nil calls the function with no arguments.
  (check (is (apply (fn () 42) nil) 42)))

(deftest "apply/closure"
  (let add (fn (a b) (+ a b)))
  (check (is (apply add (list 4 5)) 9))
  ;; A closure capturing its environment.
  (let make-adder (fn (n) (fn (x) (+ x n))))
  (check (is (apply (make-adder 10) (list 7)) 17)))

(deftest "apply/single-arg"
  (let id (fn (x) x))
  (check (is (apply id (list 42)) 42)))

(deftest "read-string/list"
  (let v (read-string "(1 2 3)"))
  (check (pair? v))
  (check (is (length v) 3))
  (check (is (nth v 0) 1))
  (check (is (nth v 2) 3)))

(deftest "read-string/atom"
  (check (is (read-string "42") 42))           ; number
  (check (is (read-string "  -7 ") -7))         ; leading whitespace ok
  (check (symbol? (read-string "foo")))         ; symbol
  (check (is (read-string "\"hi\"") "hi")))     ; string literal

(deftest "read-string/first-form-only"
  ;; Only the FIRST s-expression is read; trailing forms are ignored.
  (check (is (read-string "1 2 3") 1)))

(deftest "read-string/does-not-eval"
  ;; read-string must NOT execute the form it parses. Reading a (write-file ...) form
  ;; that would create a file must leave the filesystem untouched.
  (let path "kec-readstring-sideeffect.tmp")
  (let form (read-string (str "(write-file \"" path "\" \"boom\")")))
  (check (pair? form))                          ; we got the form back
  (check (is (car form) 'write-file))                 ; ... unevaluated
  (check (nil? (file-exists? path))))           ; ... and nothing was written
