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
;; raises: Fe binds a missing required param to nil, which would otherwise
;; silently return nil and surface as a type error far from the call.
(defn min (a . rest)
  (if (and (not a) (not rest)) (raise "min: needs at least one argument"))
  (let m a)
  (while rest
    (if (< (car rest) m) (set m (car rest)))
    (set rest (cdr rest)))
  m)

(defn max (a . rest)
  (if (and (not a) (not rest)) (raise "max: needs at least one argument"))
  (let m a)
  (while rest
    (if (< m (car rest)) (set m (car rest)))
    (set rest (cdr rest)))
  m)
