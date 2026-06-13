;; KEC Core — hof : higher-order functions (standard §4.3)
;;
;; The functions builtins.md already assumed carts could call "as if they
;; were primitives" (map, filter). Core makes that real.
;;
;; All traversals are iterative (while + accumulator + reverse), not
;; recursive: the Fe Kernel's GC root stack is a fixed 256 (standard §3), so
;; a recursive map/filter would overflow on lists longer than ~150. Iteration
;; bounds depth at a constant regardless of list length.

(defn map (f xs)
  (let acc nil)
  (while xs (= acc (cons (f (car xs)) acc)) (= xs (cdr xs)))
  (reverse acc))

(defn filter (pred xs)
  (let acc nil)
  (while xs
    (if (pred (car xs)) (= acc (cons (car xs) acc)))
    (= xs (cdr xs)))
  (reverse acc))

(defn remove (pred xs)
  (filter (fn (x) (not (pred x))) xs))

;; (fold-left f init xs) — left fold (reduce).
(defn fold-left (f init xs)
  (while xs (= init (f init (car xs))) (= xs (cdr xs)))
  init)

;; (fold-right f init xs) — right fold, as fold-left of the flipped op over
;; the reversed list (so it stays iterative).
(defn fold-right (f init xs)
  (fold-left (fn (acc x) (f x acc)) init (reverse xs)))

(defn for-each (f xs)
  (while xs (f (car xs)) (= xs (cdr xs)))
  nil)

(defn find (pred xs)
  (let r nil)
  (let done nil)
  (while (and xs (not done))
    (if (pred (car xs)) (do (= r (car xs)) (= done 1)))
    (= xs (cdr xs)))
  r)

;; (any? pred xs) — first truthy (pred x), else nil. Short-circuits.
(defn any? (pred xs)
  (let r nil)
  (while (and xs (not r))
    (= r (pred (car xs)))
    (= xs (cdr xs)))
  r)

;; (every? pred xs) — truthy (1) if all match, else nil. Short-circuits.
(defn every? (pred xs)
  (let ok 1)
  (while (and xs ok)
    (if (pred (car xs)) (= xs (cdr xs)) (= ok nil)))
  ok)

(defn count (pred xs)
  (let n 0)
  (while xs (if (pred (car xs)) (= n (+ n 1))) (= xs (cdr xs)))
  n)
