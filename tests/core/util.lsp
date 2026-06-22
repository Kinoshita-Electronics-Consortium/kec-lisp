;; KEC Core — util : prog1 / defvar (ADR-0001 B).

(deftest "util/prog1-returns-first-runs-rest"
  ;; prog1 yields the first form's value but still evaluates the later forms.
  (set %p1-flag nil)
  (let v (prog1 (+ 1 2) (set %p1-flag 1) (set %p1-flag 2)))
  (check (is v 3))           ; first value
  (check (is %p1-flag 2)))   ; later forms ran in order

(deftest "util/defvar-sets-when-unbound"
  ;; %dv-x is not yet bound, so defvar establishes it.
  (check (nil? (bound? '%dv-x)))
  (defvar %dv-x 10)
  (check (is %dv-x 10)))

(deftest "util/defvar-leaves-existing-binding"
  ;; A second defvar must NOT overwrite the live value.
  (defvar %dv-y 1)
  (check (is %dv-y 1))
  (defvar %dv-y 999)
  (check (is %dv-y 1)))      ; unchanged
