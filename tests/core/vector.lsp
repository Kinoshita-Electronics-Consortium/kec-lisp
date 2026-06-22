;; KEC Lisp — vector conformance (ADR-0003).
;; Vectors are FE_TPTR objects, so = / is compare them by IDENTITY; content is
;; checked here via (vector->list v) + equal?, or element-wise with vector-ref.

(deftest "vector/make-and-length"
  (check (is (vector-length (make-vector 5 0)) 5))
  (check (is (vector-length (make-vector 0 0)) 0))
  (check (is (vector-length (vector)) 0))
  (check (is (vector-length (vector 1 2 3)) 3)))

(deftest "vector/default-init-is-nil"
  (let v (make-vector 3 nil))
  (check (nil? (vector-ref v 0)))
  (check (nil? (vector-ref v 2))))

(deftest "vector/make-fills-with-init"
  (let v (make-vector 4 7))
  (check (is (vector-ref v 0) 7))
  (check (is (vector-ref v 3) 7)))

(deftest "vector/ref-and-set"
  (let v (vector 10 20 30))
  (check (is (vector-ref v 0) 10))
  (check (is (vector-ref v 2) 30))
  (check (is (vector-set! v 1 99) 99))   ; returns the value
  (check (is (vector-ref v 1) 99)))

(deftest "vector/predicate"
  (check (vector? (vector 1)))
  (check (vector? (make-vector 0 0)))
  (check (not (vector? 5)))
  (check (not (vector? '(1 2 3))))
  (check (not (vector? "v")))
  (check (not (vector? nil))))

(deftest "vector/bounds-and-type-errors"
  (let v (vector 1 2 3))
  (check-err (vector-ref v 3))           ; index == length
  (check-err (vector-ref v -1))
  (check-err (vector-set! v 3 0))
  (check-err (vector-ref 5 0))           ; not a vector
  (check-err (vector-length '(1 2)))
  (check-err (make-vector -1 0)))        ; negative length

(deftest "vector/to-list-and-back"
  (check (equal? (vector->list (vector 1 2 3)) '(1 2 3)))
  (check (equal? (vector->list (make-vector 0 0)) nil))
  (check (equal? (vector->list (list->vector '(a b c))) '(a b c)))
  (check (is (vector-length (list->vector '(1 2 3 4))) 4)))

(deftest "vector/fill-and-copy"
  (let v (vector 1 2 3))
  (check (equal? (vector->list (vector-fill! v 0)) '(0 0 0)))
  (let a (vector 1 2 3))
  (let b (vector-copy a))
  (vector-set! b 0 99)
  (check (is (vector-ref a 0) 1))        ; copy is independent
  (check (is (vector-ref b 0) 99)))

(deftest "vector/map-and-for-each"
  (check (equal? (vector->list (vector-map (fn (x) (* x x)) (vector 1 2 3)))
                 '(1 4 9)))
  (let sum 0)
  (vector-for-each (fn (x) (set sum (+ sum x))) (vector 4 5 6))
  (check (is sum 15)))

(deftest "vector/nested"
  (let v (vector (vector 1 2) (vector 3 4)))
  (check (is (vector-ref (vector-ref v 0) 1) 2))
  (check (is (vector-ref (vector-ref v 1) 0) 3)))
