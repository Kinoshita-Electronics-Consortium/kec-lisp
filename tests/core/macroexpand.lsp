;; KEC Lisp — macroexpand-1 conformance.

(deftest "macroexpand-1/core-macro"
  (check (equal? (macroexpand-1 '(when 1 2 3))
                 '(if 1 (do 2 3) nil))))

(deftest "macroexpand-1/non-macro-form-is-unchanged"
  (check (equal? (macroexpand-1 '(+ 1 2)) '(+ 1 2)))
  (check (is (macroexpand-1 'hello) 'hello))
  (check (is (macroexpand-1 42) 42)))

(deftest "macroexpand-1/does-not-mutate-input"
  (let form '(when 1 2))
  (check (equal? (macroexpand-1 form) '(if 1 (do 2) nil)))
  (check (equal? form '(when 1 2))))

(deftest "macroexpand-1/only-one-step"
  (defmacro expands-to-when (x)
    (list 'when x (list 'set '%macroexpand-flag 1)))
  (check (equal? (macroexpand-1 '(expands-to-when 1))
                 '(when 1 (set %macroexpand-flag 1)))))
