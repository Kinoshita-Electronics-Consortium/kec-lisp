;; KEC Core §4.7 — pred

(deftest "pred/basic"
  (check (nil? nil))
  (check (not (nil? 1)))
  (check (pair? (cons 1 2)))
  (check (pair? (list 1)))
  (check (not (pair? 1)))
  (check (not (pair? nil))))

(deftest "pred/parity"
  (check (even? 4))
  (check (even? 0))
  (check (odd? 7))
  (check (not (even? 3)))
  (check (not (odd? 8))))

(deftest "pred/types"
  (check (number? 3))
  (check (string? "x"))
  (check (symbol? 'foo))
  (check (fn? (fn () 1)))
  (check (not (number? "x")))
  (check (not (string? 3)))
  (check (not (fn? 'foo))))
