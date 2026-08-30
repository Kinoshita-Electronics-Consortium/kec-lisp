;; KEC Core — cmp : equality & comparison
;;
;; Kernel ships < <= is. Core completes the set.
;;
;; `=` is value equality. The KEC kernel names assignment
;; `set` (not `=`, as upstream Fe did), which frees `=` for its conventional
;; meaning. `=`, `==`, and `is` are the same comparison: value for numbers and
;; strings, identity for symbols and pairs. `/=` is its negation.

(defn =  (a b) (is a b))
(defn == (a b) (is a b))          ; alias for those coming from C-family langs
(defn /= (a b) (not (is a b)))

(defn >  (a b) (not (<= a b)))
(defn >= (a b) (not (<  a b)))

(defn zero?     (n) (is n 0))
(defn positive? (n) (< 0 n))
(defn negative? (n) (< n 0))

;; (min a b...) / (max a b...) -> fold over the variadic tail. Zero arguments
;; raises. The whole argument list binds to one rest symbol so the empty call
;; is distinguishable from an explicit nil argument: Fe binds a missing
;; required param to nil, so a `(a . rest)` signature cannot tell `(min)` from
;; `(min nil)`; the latter is one argument and folds to nil like any
;; single-element fold.
(defn min args
  (if (not args) (raise "min: needs at least one argument"))
  (let m (car args))
  (set args (cdr args))
  (while args
    (if (< (car args) m) (set m (car args)))
    (set args (cdr args)))
  m)

(defn max args
  (if (not args) (raise "max: needs at least one argument"))
  (let m (car args))
  (set args (cdr args))
  (while args
    (if (< m (car args)) (set m (car args)))
    (set args (cdr args)))
  m)
