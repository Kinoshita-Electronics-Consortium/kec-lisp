;; KEC Lisp — try error-message surfacing (GWP-532).
;;
;; (try thunk) returns the thunk's value on success, or an error value on
;; failure. The test harness's check-err is built on the public error? predicate.

(deftest "try/success-passes-value"
  ;; On success try returns the value unchanged (not wrapped).
  (check (is (try (fn () (+ 1 2))) 3))
  (check (is (try (fn () "ok")) "ok")))

(deftest "try/failure-is-error-pair"
  (let r (try (fn () (car 5))))   ; car of a non-pair raises
  (check (pair? r))
  (check (error? r)))

(deftest "try/failure-surfaces-message"
  (let r (try (fn () (car 5))))
  ;; error-message carries the string the runtime captured.
  (check (string? (error-message r)))
  (check (< 0 (string-length (error-message r)))))      ; non-empty message

(deftest "try/error-recognizable-by-car"
  ;; The recommended idiom: detect failure via error?.
  (let r (try (fn () (cdr 7))))
  (check (error? r))
  ;; A successful value is not a (:error . _) pair.
  (let ok (try (fn () (list 1 2))))
  (check (not (error? ok))))

(deftest "try/check-err-still-works"
  ;; check-err (harness) is built on try; it must still detect raises.
  (check-err (car 5))
  (check-err (cdr 9))
  (check (is (+ 1 1) 2)))         ; a normal passing check alongside
