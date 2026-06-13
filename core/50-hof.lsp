;; KEC Core — hof : higher-order functions
;;
;; All traversals are iterative (while + accumulator + reverse), not recursive:
;; the GC root stack is small and fixed (256 on memory-tight hosts, raised on
;; desktop), so a recursive map/filter would overflow on long lists. Iteration
;; keeps depth constant regardless of list length.

(defn map (f xs)
  (let acc nil)
  (while xs (set acc (cons (f (car xs)) acc)) (set xs (cdr xs)))
  (reverse acc))

(defn filter (pred xs)
  (let acc nil)
  (while xs
    (if (pred (car xs)) (set acc (cons (car xs) acc)))
    (set xs (cdr xs)))
  (reverse acc))

(defn remove (pred xs)
  (filter (fn (x) (not (pred x))) xs))

;; (fold-left f init xs) — left fold (reduce).
(defn fold-left (f init xs)
  (while xs (set init (f init (car xs))) (set xs (cdr xs)))
  init)

;; (fold-right f init xs) — right fold, as fold-left of the flipped op over
;; the reversed list (so it stays iterative).
(defn fold-right (f init xs)
  (fold-left (fn (acc x) (f x acc)) init (reverse xs)))

(defn for-each (f xs)
  (while xs (f (car xs)) (set xs (cdr xs)))
  nil)

(defn find (pred xs)
  (let r nil)
  (let done nil)
  (while (and xs (not done))
    (if (pred (car xs)) (do (set r (car xs)) (set done 1)))
    (set xs (cdr xs)))
  r)

;; (any? pred xs) — first truthy (pred x), else nil. Short-circuits.
(defn any? (pred xs)
  (let r nil)
  (while (and xs (not r))
    (set r (pred (car xs)))
    (set xs (cdr xs)))
  r)

;; (every? pred xs) — truthy (1) if all match, else nil. Short-circuits.
(defn every? (pred xs)
  (let ok 1)
  (while (and xs ok)
    (if (pred (car xs)) (set xs (cdr xs)) (set ok nil)))
  ok)

(defn count (pred xs)
  (let n 0)
  (while xs (if (pred (car xs)) (set n (+ n 1))) (set xs (cdr xs)))
  n)
