;; KEC Core — sort : stable, iterative merge sort
;;
;; (sort xs less?) -> a new list with the elements of xs ordered by the binary
;; predicate less? (less? a b is truthy when a should come before b). The input
;; list is not mutated.
;;
;; Bottom-up (iterative) merge sort: start with each element as a length-1 run,
;; then repeatedly merge adjacent runs — doubling run length each pass — until a
;; single run remains. Every loop is a `while`; nothing recurses on list length,
;; so a 1000-element sort can't exhaust the bounded GC root stack. The merge is
;; stable: on a tie it takes from the left run first, so equal elements keep
;; their original relative order.

;; (%merge a b less?) -> the two sorted lists a and b merged into one sorted
;; list. Stable: when neither is strictly less, the element from a wins.
;; Iterative — builds the result reversed, then reverses once (the Core idiom).
(defn %merge (a b less?)
  (let out nil)
  (while (and a b)
    (if (less? (car b) (car a))
        (do (set out (cons (car b) out)) (set b (cdr b)))
        (do (set out (cons (car a) out)) (set a (cdr a)))))
  ;; drain whichever run remains
  (while a (set out (cons (car a) out)) (set a (cdr a)))
  (while b (set out (cons (car b) out)) (set b (cdr b)))
  (reverse out))

;; (%merge-pass runs less?) -> one bottom-up pass: merge runs pairwise. `runs`
;; is a list of sorted runs; returns a list of half as many (a trailing odd run
;; passes through untouched). Iterative.
(defn %merge-pass (runs less?)
  (let out nil)
  (while runs
    (if (cdr runs)
        (do
          (set out (cons (%merge (car runs) (car (cdr runs)) less?) out))
          (set runs (cdr (cdr runs))))
        (do
          (set out (cons (car runs) out))
          (set runs nil))))
  (reverse out))

(defn sort (xs less?)
  (if (nil? xs)
      nil
      (do
        ;; seed: one length-1 run per element (order preserved)
        (let runs nil)
        (let tmp (reverse xs))            ; reverse then re-reverse keeps order
        (while tmp
          (set runs (cons (cons (car tmp) nil) runs))
          (set tmp (cdr tmp)))
        ;; merge passes until a single run remains
        (while (cdr runs)
          (set runs (%merge-pass runs less?)))
        (car runs))))
