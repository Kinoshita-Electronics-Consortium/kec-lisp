;; KEC Core — sort conformance (GWP-532).
;;
;; (sort xs less?) returns a new list with xs ordered by the binary predicate
;; less?. It is an iterative, stable, bottom-up merge sort — GC-stack-safe on a
;; long list (no O(n) recursion depth).

(deftest "sort/empty-singleton"
  (check (nil? (sort nil <)))
  (check (is (length (sort nil <)) 0))
  (let one (sort (list 7) <))
  (check (is (length one) 1))
  (check (is (nth one 0) 7)))

(deftest "sort/basic"
  (let s (sort (list 3 1 2) <))
  (check (is (nth s 0) 1))
  (check (is (nth s 1) 2))
  (check (is (nth s 2) 3))
  ;; descending with a flipped predicate.
  (let d (sort (list 3 1 2) (fn (a b) (< b a))))
  (check (is (nth d 0) 3))
  (check (is (nth d 2) 1)))

(deftest "sort/duplicates"
  (let s (sort (list 2 1 2 1 3 1) <))
  (check (is (length s) 6))
  (check (is (nth s 0) 1))
  (check (is (nth s 1) 1))
  (check (is (nth s 2) 1))
  (check (is (nth s 3) 2))
  (check (is (nth s 5) 3)))

(deftest "sort/does-not-mutate"
  ;; sort returns a new list; the input is unchanged.
  (let xs (list 3 1 2))
  (sort xs <)
  (check (is (nth xs 0) 3))
  (check (is (nth xs 1) 1))
  (check (is (nth xs 2) 2)))

;; --- stability ---
;; Sort pairs (key . tag) by key only. A stable sort keeps equal-key elements in
;; their original relative order, so the tags within a key group stay ascending.
(deftest "sort/stable"
  (let data (list (cons 1 'a) (cons 2 'b) (cons 1 'c) (cons 2 'd) (cons 1 'e)))
  (let s (sort data (fn (p q) (< (car p) (car q)))))
  ;; keys: 1 1 1 2 2
  (check (is (car (nth s 0)) 1))
  (check (is (car (nth s 2)) 1))
  (check (is (car (nth s 3)) 2))
  ;; tags within key 1, in original order: a c e
  (check (is (cdr (nth s 0)) 'a))
  (check (is (cdr (nth s 1)) 'c))
  (check (is (cdr (nth s 2)) 'e))
  ;; tags within key 2, in original order: b d
  (check (is (cdr (nth s 3)) 'b))
  (check (is (cdr (nth s 4)) 'd)))

;; --- scale: 1000 elements must not exhaust the GC root stack ---
(deftest "sort/1000-elements"
  ;; Build a 1000-long list in a pseudo-shuffled order via an LCG, then sort.
  (let n 1000)
  (let xs nil)
  (let seed 1)
  (dotimes (i n)
    (set seed (mod (+ (* seed 1103515245) 12345) 2147483648))
    (set xs (cons (mod seed 100000) xs)))
  (let s (sort xs <))
  (check (is (length s) n))
  ;; fully non-decreasing
  (let ok 1)
  (let prev (nth s 0))
  (dolist (x (cdr s))
    (if (< x prev) (set ok nil))
    (set prev x))
  (check ok))
