;; Kernel behaviour pins — properties Core relies on (standard §3).

(deftest "kernel/arith"
  (check (is (+ 1 2) 3))
  (check (is (* 2 3 4) 24))
  (check (is (- 10 3 2) 5))
  (check (is (/ 7 2) 3.5)))

(deftest "kernel/nil-is-false"
  (check (is (if nil 1 2) 2))
  (check (not nil))
  (check (if (cons 1 2) 1 nil)))

(deftest "kernel/is"
  (check (is 3 3))
  (check (is "ab" "ab"))          ; strings compare structurally
  (check (not (is 3 4)))
  (check (is 'sym 'sym)))         ; symbols compare by identity (interned)

(deftest "kernel/closure"
  (set mkcounter (fn (n) (fn () (set n (+ n 1)) n)))
  (set c (mkcounter 10))
  (check (is (c) 11))
  (check (is (c) 12)))

(deftest "kernel/variadic-rest"
  (set collect (fn args args))                 ; whole arg list
  (check (is (length (collect 1 2 3)) 3))
  (set head-rest (fn (a . rest) rest))          ; dotted rest
  (check (is (length (head-rest 0 1 2)) 2)))

(deftest "kernel/error-recovers"
  (check-err (car 5)))            ; calling car on a non-pair raises
