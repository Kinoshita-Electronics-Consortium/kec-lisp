;; KEC Core §4.2 — list

(deftest "list/nth"
  (check (is (nth (list 10 20 30) 0) 10))
  (check (is (nth (list 10 20 30) 2) 30))
  (check (nil? (nth (list 1 2) 5))))

(deftest "list/length-reverse"
  (check (is (length (list 1 2 3 4)) 4))
  (check (is (length nil) 0))
  (check (is (nth (reverse (list 1 2 3)) 0) 3)))

(deftest "list/append"
  (let r (append (list 1 2) (list 3 4)))
  (check (is (length r) 4))
  (check (is (nth r 3) 4)))

(deftest "list/last-member-assoc"
  (check (is (last (list 1 2 9)) 9))
  (check (is (car (member 2 (list 1 2 3))) 2))
  (check (nil? (member 9 (list 1 2 3))))
  (check (is (cdr (assoc 'b (list (cons 'a 1) (cons 'b 2)))) 2))
  (check (nil? (assoc 'z (list (cons 'a 1))))))

(deftest "list/take-drop-range"
  (check (is (length (take (list 1 2 3 4 5) 3)) 3))
  (check (is (car (drop (list 1 2 3 4) 2)) 3))
  (check (is (length (range 0 5)) 5))
  (check (is (nth (range 3 7) 0) 3))
  (check (is (last (range 3 7)) 6)))

(deftest "list/nth-negative"
  ;; nil for a negative index, same as past-the-end — never element 0.
  (check (nil? (nth (list 'a 'b 'c) -1)))
  (check (nil? (nth (list 'a 'b 'c) -100)))
  (check (nil? (nth nil -1))))

(deftest "list/take-drop-fractional"
  ;; Documented: take/drop strip while 0 < n, so a fractional count rounds UP.
  (check (is (length (take (list 1 2 3 4 5) 2.5)) 3))
  (check (is (car (drop (list 1 2 3 4 5) 2.5)) 4)))

(deftest "list/large-iterative"        ; regression: bounded GC-stack depth
  (check (is (length (append (range 0 500) (range 0 500))) 1000))
  (check (is (last (take (range 0 1000) 300)) 299))
  (check (is (car (member 750 (range 0 1000))) 750)))
