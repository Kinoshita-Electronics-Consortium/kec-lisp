;; KEC Core §4.3 — hof

(deftest "hof/map-filter-remove"
  (check (is (nth (map (fn (x) (* x x)) (list 1 2 3)) 2) 9))
  (check (is (length (filter (fn (x) (> x 2)) (list 1 2 3 4))) 2))
  (check (is (length (remove (fn (x) (> x 2)) (list 1 2 3 4))) 2)))

(deftest "hof/fold"
  (check (is (fold-left + 0 (list 1 2 3 4)) 10))
  (check (is (fold-left (fn (a x) (+ a 1)) 0 (list 9 9 9)) 3))
  (let r (fold-right cons nil (list 1 2 3)))   ; rebuilds the list
  (check (is (car r) 1))
  (check (is (nth r 2) 3)))

(deftest "hof/find-any-every-count"
  (check (is (find (fn (x) (> x 2)) (list 1 2 3 4)) 3))
  (check (nil? (find (fn (x) (> x 9)) (list 1 2 3))))
  (check (any? (fn (x) (is x 2)) (list 1 2 3)))
  (check (every? (fn (x) (> x 0)) (list 1 2 3)))
  (check (not (every? (fn (x) (> x 1)) (list 1 2 3))))
  (check (is (count (fn (x) (odd? x)) (list 1 2 3 4 5)) 3)))

(deftest "hof/for-each"
  (set total 0)
  (for-each (fn (x) (set total (+ total x))) (list 4 5 6))
  (check (is total 15)))

(deftest "hof/large-lists-iterative"   ; regression: recursive Core overflowed ~150
  (check (is (length (map (fn (x) (+ x 1)) (range 0 1000))) 1000))
  (check (is (length (filter (fn (x) (even? x)) (range 0 1000))) 500))
  (check (is (fold-left + 0 (range 0 1000)) 499500)))
