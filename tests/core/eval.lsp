;; KEC Core — eval + read-all : evaluating data forms in the live image.
;;
;; `eval` is the keystone of "the editor is its own Lisp" (nEmacs): evaluate a
;; form read from a buffer (eval-defun / scratch REPL / config-as-code). It is a
;; FULL-tier capability (bound alongside `load`), not a SANDBOX cart primitive —
;; the deliberate "no eval in the sandbox" stance is preserved by binding.
;; `read-all` parses every top-level form of a string (config-as-code, multi-
;; form paste) — the multi-form companion to `read-string`.

(deftest "eval/basic"
  (check (is (eval '(+ 1 2)) 3))
  (check (is (eval 42) 42))                  ; self-evaluating
  (check (is (eval ''foo) 'foo))             ; (quote foo) -> foo
  (check (is (eval (list '+ 10 20)) 30)))    ; a constructed form

(deftest "eval/special-forms-and-nesting"
  ;; the exact cases `apply` cannot do (special forms, nested calls)
  (check (is (eval '(if nil 'a (+ 10 20))) 30))
  (check (is (eval '(if 1 (* 2 3) 'no)) 6))
  (check (is (eval '(do (+ 1 1) (+ 2 2))) 4)))

(deftest "eval/repl-path"
  ;; read-string + eval = a one-form REPL
  (check (is (eval (read-string "(+ 2 3)")) 5))
  ;; eval can define; the definition becomes callable (eval-defun / config)
  (eval (read-string "(defn %sq (n) (* n n))"))
  (check (is (%sq 6) 36)))

(deftest "read-all/parses-every-form"
  (check (is (length (read-all "(a) (b) (c)")) 3))
  (check (equal? (read-all "1 2 3") (list 1 2 3)))
  (check (equal? (read-all "(+ 1 2)") (list (list '+ 1 2))))
  (check (not (read-all "")))                ; empty -> nil
  (check (not (read-all "   ")))             ; blank -> nil
  (check (is (length (read-all "(x) ; comment\n(y)")) 2)))  ; comments skipped

(deftest "read-all/feeds-eval-for-config"
  ;; eval each form of a multi-form string, in order (config-as-code)
  (for-each eval (read-all "(set %ra-x 7) (set %ra-y (* %ra-x 3))"))
  (check (is %ra-x 7))
  (check (is %ra-y 21)))

(deftest "read-all/does-not-grow-the-gc-stack-per-form"
  ;; Pass 2 (reversing into source order) used to push one GC root per form,
  ;; so a few thousand top-level forms overflowed the GC stack (desktop
  ;; GCSTACKSIZE 8192). The restore/push idiom keeps the root set bounded.
  (check (is (length (read-all (string-repeat "1 " 5000))) 5000)))

(deftest "read-all/syntax-error-is-catchable"
  (check-err (read-all "(a (b)"))
  (check (error? (try (fn () (read-all "(a (b)"))))))
