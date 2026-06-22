;; KEC Core — recover : error-recovery macros (ADR-0001 A).

(deftest "recover/unwind-protect-normal-runs-cleanup"
  ;; Cleanup runs on the normal path; the body's value is returned.
  (set %uw-flag nil)
  (let v (unwind-protect (+ 2 3) (set %uw-flag 1)))
  (check (is v 5))
  (check (is %uw-flag 1)))

(deftest "recover/unwind-protect-error-runs-cleanup-and-reraises"
  ;; On the error path cleanup STILL runs, and the error is re-raised — so an
  ;; outer try sees the failure AND the cleanup flag is set.
  (set %uw-flag nil)
  (let r (try (fn () (unwind-protect (raise "boom") (set %uw-flag 1)))))
  (check (error? r))           ; error propagated past unwind-protect
  (check (is %uw-flag 1)))     ; cleanup ran anyway

(deftest "recover/ignore-errors"
  (check (is (ignore-errors (+ 1 1)) 2))     ; body value on success
  (check (nil? (ignore-errors (raise "x"))))  ; nil on raise
  (check (nil? (ignore-errors (car 5)))))     ; nil on a kernel-raised error

(deftest "recover/condition-case-error-binds-var"
  ;; On error the handler value is returned and var is bound to the error value.
  (let r (condition-case e (raise "nope")
           (e (if (error? e) 'caught 'wrong))))
  (check (is r 'caught)))

(deftest "recover/condition-case-success-returns-body"
  (let r (condition-case e (+ 10 20)
           (e 'should-not-run)))
  (check (is r 30)))

(deftest "recover/macroexpand-full-and-identity"
  ;; when nests if+do; macroexpand drives macroexpand-1 to a fixpoint.
  (check (equal? (macroexpand '(when 1 2)) '(if 1 (do 2) nil)))
  ;; A non-macro form is returned unchanged (identity fixpoint, no loop hang).
  (check (equal? (macroexpand '(+ 1 2)) '(+ 1 2)))
  (check (is (macroexpand 'sym) 'sym)))
