;; KEC Lisp — small error vocabulary.

(deftest "error/constructor-and-accessors"
  (let e (error "boom"))
  (check (error? e))
  (check (is (car e) ':error))
  (check (is (error-message e) "boom")))

(deftest "error/predicate-shape"
  (check (not (error? nil)))
  (check (not (error? ':error)))
  (check (not (error? (cons ':ok "fine"))))
  (check (error? (cons ':error "raw"))))

(deftest "error/try-result-uses-public-vocabulary"
  (let r (try (fn () (car 5))))
  (check (error? r))
  (check (string? (error-message r)))
  (check (< 0 (string-length (error-message r)))))

(deftest "error/raise-is-catchable"
  (let r (try (fn () (raise "bad input"))))
  (check (error? r))
  (check (is (error-message r) "bad input"))
  (check-err (raise "uncaught")))
