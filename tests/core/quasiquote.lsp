;; KEC Core — quasiquote reader sugar and expansion.

(deftest "quasiquote/literals"
  (check (equal? `(1 2 3) (list 1 2 3)))
  (check (equal? `foo 'foo))
  (check (equal? `(a (b c)) (list 'a (list 'b 'c)))))

(deftest "quasiquote/unquote"
  (let x 7)
  (check (equal? `(a ,x c) (list 'a 7 'c)))
  (check (equal? `(sum ,(+ 1 2)) (list 'sum 3))))

(deftest "quasiquote/unquote-splicing"
  (let xs (list 2 3))
  (check (equal? `(1 ,@xs 4) (list 1 2 3 4)))
  (check (equal? `(a ,@(list 'b 'c) d) (list 'a 'b 'c 'd))))

(deftest "quasiquote/macro-ergonomics"
  (defmacro qq-when (test . body)
    `(if ,test (do ,@body) nil))
  (let x 0)
  (qq-when 1 (set x 42))
  (check (is x 42)))
