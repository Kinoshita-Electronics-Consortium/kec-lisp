;; KEC Core — list : list & sequence operations (standard §4.2)
;;
;; Kernel ships cons/car/cdr/setcar/setcdr/list. Core adds traversal and
;; construction. Recursive helpers here are convenience-tier (board, REPL,
;; nEmacs) — per §4.2, per-frame cart loops use while + setcar/setcdr.
;; This file uses only the kernel (not the later predicate names), so it can
;; load before pred.

;; (nth xs i) -> 0-indexed element; nil past the end.
(defn nth (xs i)
  (while (< 0 i) (= xs (cdr xs)) (= i (- i 1)))
  (car xs))

;; (length xs) -> proper-list length.
(defn length (xs)
  (let n 0)
  (while xs (= n (+ n 1)) (= xs (cdr xs)))
  n)

;; (reverse xs) -> reversed list.
(defn reverse (xs)
  (let acc nil)
  (while xs (= acc (cons (car xs) acc)) (= xs (cdr xs)))
  acc)

;; (append xs ys) -> concatenate (non-destructive copy of xs).
;; Iterative (cons reverse(a) onto b) so list length, not GC-stack depth,
;; bounds it — the kernel's root stack is a fixed 256 (standard §4.2).
(defn append (a b)
  (let r b)
  (let ra (reverse a))
  (while ra (= r (cons (car ra) r)) (= ra (cdr ra)))
  r)

;; (last xs) -> final element.
(defn last (xs)
  (while (cdr xs) (= xs (cdr xs)))
  (car xs))

;; (member x xs) -> tail beginning at first (is x ...), else nil.
(defn member (x xs)
  (let r nil)
  (while (and xs (not r))
    (if (is (car xs) x) (= r xs) (= xs (cdr xs))))
  r)

;; (assoc k alist) -> first pair whose car is (is k ...), else nil.
(defn assoc (k alist)
  (let r nil)
  (while (and alist (not r))
    (if (is (car (car alist)) k) (= r (car alist)) (= alist (cdr alist))))
  r)

;; (take xs n) -> first n elements.
(defn take (xs n)
  (let acc nil)
  (while (and xs (< 0 n))
    (= acc (cons (car xs) acc))
    (= xs (cdr xs))
    (= n (- n 1)))
  (reverse acc))

;; (drop xs n) -> xs with the first n elements removed.
(defn drop (xs n)
  (while (and xs (< 0 n)) (= xs (cdr xs)) (= n (- n 1)))
  xs)

;; (range a b) -> (a a+1 ... b-1).
(defn range (a b)
  (let acc nil)
  (let i (- b 1))
  (while (<= a i) (= acc (cons i acc)) (= i (- i 1)))
  acc)
