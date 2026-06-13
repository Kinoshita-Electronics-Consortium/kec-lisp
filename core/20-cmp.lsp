;; KEC Core — cmp : equality & comparison (standard §4.1)
;;
;; Kernel ships < <= is. Core completes the set.
;;
;; NOTE ON `=` (deviation from §4.1, surfaced for an ADR-0037 amendment):
;; §4.1 names numeric equality `(= a b)`. But the Fe Kernel's `=` is the
;; ASSIGNMENT special form (P_SET) and the kernel is frozen (standard §3) —
;; it cannot be rebound without breaking all assignment, including Core's own.
;; KEC Lisp therefore exposes numeric equality as `==` / inequality as `/=`.
;; Kernel `is` already compares numbers by value, so `==` is `is` contracted
;; to numbers. Recommend §4.1 adopt `==` as the canonical name.

(defn >  (a b) (not (<= a b)))
(defn >= (a b) (not (<  a b)))
(defn == (a b) (is a b))         ; numeric equality (see note above)
(defn /= (a b) (not (is a b)))   ; numeric inequality

(defn zero?     (n) (is n 0))
(defn positive? (n) (< 0 n))
(defn negative? (n) (< n 0))

;; (min a b...) / (max a b...) -> fold over the variadic tail.
(defn min (a . rest)
  (let m a)
  (while rest
    (if (< (car rest) m) (= m (car rest)))
    (= rest (cdr rest)))
  m)

(defn max (a . rest)
  (let m a)
  (while rest
    (if (< m (car rest)) (= m (car rest)))
    (= rest (cdr rest)))
  m)
