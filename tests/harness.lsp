;; KEC Lisp — test harness (xUnit, authored in KEC Lisp).
;;
;; Usage:
;;   (deftest "group/name"
;;     (check (is (+ 1 2) 3))         ; passes when the form is truthy
;;     (check-err (car 5)))           ; passes when the form raises
;;   ... then (test-report) prints a summary and returns the failure count.
;;
;; `kec test FILE...` loads this harness, then each FILE, then calls
;; (test-report); it exits 0 only when every check passed and every file
;; loaded cleanly, 1 otherwise.

(set %tests-run 0)
(set %tests-failed 0)
(set %current-test "")

;; (deftest name body...) — set the current label, run the body. The body runs
;; under `try`, so a raise counts as one failed check instead of aborting the
;; rest of the file — a crashed suite must never read as green.
(set deftest (mac (name . body)
  (list '%deftest name (cons 'fn (cons nil body)))))

(defn %deftest (name thunk)
  (set %current-test name)
  (let res (try thunk))
  (if (error? res)
      (do
        (set %tests-run (+ %tests-run 1))
        (set %tests-failed (+ %tests-failed 1))
        (princ "  FAIL [") (princ name) (princ "] raised: ")
        (princ (error-message res)) (newline))
      nil))

(defn %check (result text)
  (set %tests-run (+ %tests-run 1))
  (if result
      nil
      (do
        (set %tests-failed (+ %tests-failed 1))
        (princ "  FAIL [") (princ %current-test) (princ "] ") (princ text) (newline))))

;; (check expr) — expr must evaluate truthy; on failure print its source.
(set check (mac (expr)
  (list '%check expr (repr expr))))

;; (check-err expr) — expr must raise an error.
;; (try ...) returns the value on success, or an error value on failure.
(set %error? error?)
(set check-err (mac (expr)
  (list '%check
        (list '%error? (list 'try (list 'fn nil expr)))
        (str "expected error: " (repr expr)))))

(defn test-report ()
  (newline)
  (princ %tests-run) (princ " checks, ") (princ %tests-failed) (princ " failed")
  (newline)
  %tests-failed)
