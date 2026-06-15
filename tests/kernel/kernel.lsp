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

(deftest "kernel/string-escape-eof"
  ; backslash at EOF in a string must raise "unclosed string", not overflow
  (check-err (read-string "\"\\")))

;; fe_write detects cycles by borrowing GCMARKBIT, then clears it in
;; unmarkpairs. The mark bit lives in the low byte of a pair's car field, so a
;; *leaked* mark corrupts the car pointer — making post-print walkability a
;; direct test of mark restoration (no GC needed). `repr` runs fe_write twice
;; internally (measure + fill), so a stale mark would also skew the two passes.
(deftest "kernel/circular-print"
  ; tail-cycle: x's last cdr points back at x. Prints finite, ends in "...".
  (set x (list 1 2 3))
  (setcdr (cdr (cdr x)) x)
  (check (is (repr x) "(1 2 3 ...)"))
  ; head-cycle: car of the head is the head itself.
  (set y (list 1 2 3))
  (setcar y y)
  (check (is (repr y) "(... 2 3)"))
  ; after printing, the cycle is intact and pointers are uncorrupted —
  ; proves unmarkpairs cleared every borrowed mark bit.
  (check (is (cdr (cdr (cdr x))) x))      ; identity: the cycle still closes on x
  (check (is (car (cdr (cdr (cdr x)))) 1)) ; walk through the back-edge → x[0]
  (check (is (car x) 1))
  ; reprʼing twice yields the same string — marks don't accumulate.
  (check (is (repr x) (repr x))))
