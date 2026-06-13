;; KEC Core — cmp : equality & comparison (standard §4.1)
;;
;; Kernel ships < <= is. Core completes the set.
;;
;; `=` is value equality (standard §4.1). The KEC kernel names assignment
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

;; (min a b...) / (max a b...) -> fold over the variadic tail.
(defn min (a . rest)
  (let m a)
  (while rest
    (if (< (car rest) m) (set m (car rest)))
    (set rest (cdr rest)))
  m)

(defn max (a . rest)
  (let m a)
  (while rest
    (if (< m (car rest)) (set m (car rest)))
    (set rest (cdr rest)))
  m)
