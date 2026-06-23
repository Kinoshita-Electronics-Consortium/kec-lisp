;; KEC Core — container : Lisp conveniences over the vector/matrix/hash/blob C
;; primitives (ADR-0003). The primitives live in host/containers.c:
;;   make-vector vector vector-ref vector-set! vector-length vector?
;;   make-matrix matrix-ref matrix-set! matrix-rows matrix-cols matrix?
;;   make-blob blob-ref blob-set! blob-length blob?
;;   make-hash-table hash-set! hash-ref hash-has? hash-del! hash-count
;;   hash-keys hash-table?
;; Loads after the higher-order functions (50) so it can use map / for-each.
;; Written iteratively (while + index), like the rest of Core, so a long vector
;; can't exhaust the bounded GC stack.

;; (vector->list v) — a fresh list of v's elements, in order.
(defn vector->list (v)
  (let out nil)
  (let i (vector-length v))
  (while (< 0 i)
    (set i (- i 1))
    (set out (cons (vector-ref v i) out)))
  out)

;; (list->vector xs) — a fresh vector holding the elements of list xs.
(defn list->vector (xs)
  (let v (make-vector (length xs) nil))
  (let i 0)
  (while xs
    (vector-set! v i (car xs))
    (set i (+ i 1))
    (set xs (cdr xs)))
  v)

;; (vector-fill! v x) — set every slot of v to x; returns v.
(defn vector-fill! (v x)
  (let i (vector-length v))
  (while (< 0 i)
    (set i (- i 1))
    (vector-set! v i x))
  v)

;; (vector-copy v) — a fresh vector with the same elements as v.
(defn vector-copy (v)
  (let n (vector-length v))
  (let out (make-vector n nil))
  (let i 0)
  (while (< i n)
    (vector-set! out i (vector-ref v i))
    (set i (+ i 1)))
  out)

;; (vector-for-each f v) — call (f element) for each element, in order; nil.
(defn vector-for-each (f v)
  (let n (vector-length v))
  (let i 0)
  (while (< i n)
    (f (vector-ref v i))
    (set i (+ i 1))))

;; (vector-map f v) — a fresh vector of (f element) for each element.
(defn vector-map (f v)
  (let n (vector-length v))
  (let out (make-vector n nil))
  (let i 0)
  (while (< i n)
    (vector-set! out i (f (vector-ref v i)))
    (set i (+ i 1)))
  out)

;; (matrix-fill! m x) — set every matrix cell to x; returns m.
(defn matrix-fill! (m x)
  (let rows (matrix-rows m))
  (let cols (matrix-cols m))
  (let r 0)
  (while (< r rows)
    (let c 0)
    (while (< c cols)
      (matrix-set! m r c x)
      (set c (+ c 1)))
    (set r (+ r 1)))
  m)

;; (matrix-for-each f m) — call (f cell) in row-major order; nil.
(defn matrix-for-each (f m)
  (let rows (matrix-rows m))
  (let cols (matrix-cols m))
  (let r 0)
  (while (< r rows)
    (let c 0)
    (while (< c cols)
      (f (matrix-ref m r c))
      (set c (+ c 1)))
    (set r (+ r 1))))

;; (matrix-map f m) — a fresh matrix of (f cell), preserving dimensions.
(defn matrix-map (f m)
  (let rows (matrix-rows m))
  (let cols (matrix-cols m))
  (let out (make-matrix rows cols nil))
  (let r 0)
  (while (< r rows)
    (let c 0)
    (while (< c cols)
      (matrix-set! out r c (f (matrix-ref m r c)))
      (set c (+ c 1)))
    (set r (+ r 1)))
  out)

;; (hash-values h) — list of values, order matching (hash-keys h).
(defn hash-values (h)
  (map (fn (k) (hash-ref h k)) (hash-keys h)))

;; (hash->alist h) — list of (key . value) pairs.
(defn hash->alist (h)
  (map (fn (k) (cons k (hash-ref h k))) (hash-keys h)))

;; (alist->hash al) — a hash table from an alist of (key . value); later
;; pairs overwrite earlier ones.
(defn alist->hash (al)
  (let h (make-hash-table))
  (for-each (fn (kv) (hash-set! h (car kv) (cdr kv))) al)
  h)

;; (hash-for-each f h) — call (f key value) for each live entry; returns nil.
(defn hash-for-each (f h)
  (for-each (fn (k) (f k (hash-ref h k))) (hash-keys h)))
