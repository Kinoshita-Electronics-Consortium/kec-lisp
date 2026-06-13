;; KEC Lisp — test harness (xUnit, authored in KEC Lisp).
;;
;; Usage:
;;   (deftest "group/name"
;;     (check (is (+ 1 2) 3))         ; passes when the form is truthy
;;     (check-err (car 5)))           ; passes when the form raises
;;   ... then (test-report) prints a summary and returns the failure count.
;;
;; `kec test FILE...` loads this harness, then each FILE, then calls
;; (test-report); its exit code is the number of failed checks.

(= %tests-run 0)
(= %tests-failed 0)
(= %current-test "")

;; (deftest name body...) — set the current label, run the body.
(= deftest (mac (name . body)
  (cons 'do (cons (list '= '%current-test name) body))))

(defn %check (result text)
  (= %tests-run (+ %tests-run 1))
  (if result
      nil
      (do
        (= %tests-failed (+ %tests-failed 1))
        (princ "  FAIL [") (princ %current-test) (princ "] ") (princ text) (newline))))

;; (check expr) — expr must evaluate truthy; on failure print its source.
(= check (mac (expr)
  (list '%check expr (repr expr))))

;; (check-err expr) — expr must raise an error.
(= check-err (mac (expr)
  (list '%check
        (list 'is (list 'try (list 'fn nil expr)) '':error)
        (str "expected error: " (repr expr)))))

(defn test-report ()
  (newline)
  (princ %tests-run) (princ " checks, ") (princ %tests-failed) (princ " failed")
  (newline)
  %tests-failed)
