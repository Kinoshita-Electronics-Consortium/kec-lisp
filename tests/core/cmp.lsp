;; KEC Core §4.1 — cmp

(deftest "cmp/order"
  (check (> 5 3))
  (check (not (> 3 5)))
  (check (>= 4 4))
  (check (>= 5 4))
  (check (not (>= 3 4))))

(deftest "cmp/eq"
  (check (= 3 3))                  ; = is value equality (kernel assign is `set`)
  (check (not (= 3 4)))
  (check (= "ab" "ab"))
  (check (== 3 3))
  (check (/= 3 4))
  (check (not (/= 3 3))))

(deftest "cmp/sign"
  (check (zero? 0))
  (check (not (zero? 1)))
  (check (positive? 2))
  (check (negative? -2))
  (check (not (negative? 0))))

(deftest "cmp/minmax"
  (check (is (min 3 1 2) 1))
  (check (is (max 3 9 2 7) 9))
  (check (is (min 5) 5))
  (check (is (max -4 -9) -4)))
