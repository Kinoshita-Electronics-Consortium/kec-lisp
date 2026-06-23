;; KEC Lisp — binary blob conformance.

(deftest "blob/make-length-and-predicate"
  (let b (make-blob 4 7))
  (check (blob? b))
  (check (not (blob? "bytes")))
  (check (not (blob? (vector 1))))
  (check (is (blob-length b) 4))
  (check (is (blob-ref b 0) 7))
  (check (is (blob-ref b 3) 7)))

(deftest "blob/default-init-and-set"
  (let b (make-blob 3))
  (check (is (blob-ref b 0) 0))
  (check (is (blob-set! b 1 255) 255))
  (check (is (blob-ref b 1) 255))
  (check (is (blob-set! b 2 0) 0))
  (check (is (blob-ref b 2) 0)))

(deftest "blob/validation"
  (let b (make-blob 2 0))
  (check-err (make-blob -1 0))
  (check-err (make-blob 1.5 0))
  (check-err (make-blob 1e39 0))
  (check-err (make-blob 1 -1))
  (check-err (make-blob 1 256))
  (check-err (make-blob 1 1.5))
  (check-err (make-blob 1 1e39))
  (check-err (blob-ref b -1))
  (check-err (blob-ref b 2))
  (check-err (blob-ref b 0.5))
  (check-err (blob-set! b 0 -1))
  (check-err (blob-set! b 0 256))
  (check-err (blob-set! b 0 1.5))
  (check-err (blob-set! b 0 1e39))
  (check-err (blob-length (vector 1 2))))
