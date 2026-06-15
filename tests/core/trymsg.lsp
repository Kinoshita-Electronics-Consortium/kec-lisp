;; KEC Lisp — try error-message surfacing (GWP-532).
;;
;; (try thunk) returns the thunk's value on success, or (:error . "message") on
;; failure — a pair whose car is :error (so it stays recognizable) and whose cdr
;; is the captured error string. The test harness's check-err is built on this.

(deftest "try/success-passes-value"
  ;; On success try returns the value unchanged (not wrapped).
  (check (is (try (fn () (+ 1 2))) 3))
  (check (is (try (fn () "ok")) "ok")))

(deftest "try/failure-is-error-pair"
  (let r (try (fn () (car 5))))   ; car of a non-pair raises
  (check (pair? r))
  (check (is (car r) ':error)))   ; quote — a bare keyword would be evaluated

(deftest "try/failure-surfaces-message"
  (let r (try (fn () (car 5))))
  ;; The cdr carries the error string the runtime captured.
  (check (string? (cdr r)))
  (check (< 0 (string-length (cdr r)))))      ; non-empty message

(deftest "try/error-recognizable-by-car"
  ;; The recommended idiom: detect failure via (car r).
  (let r (try (fn () (cdr 7))))
  (check (is (car r) ':error))
  ;; A successful value is not a (:error . _) pair.
  (let ok (try (fn () (list 1 2))))
  (check (not (and (pair? ok) (is (car ok) ':error)))))

(deftest "try/check-err-still-works"
  ;; check-err (harness) is built on try; it must still detect raises.
  (check-err (car 5))
  (check-err (cdr 9))
  (check (is (+ 1 1) 2)))         ; a normal passing check alongside
