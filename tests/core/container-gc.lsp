;; KEC Lisp — container GC integration (ADR-0003).
;;
;; Vectors and hash tables are FE_TPTR objects whose elements/keys/values live
;; in the Fe arena. Correctness depends on two installed handlers:
;;   - the MARK handler keeping held containers' contents alive across a GC, and
;;   - the GC handler freeing the backing of collected (throwaway) containers.
;; These tests churn enough allocation to force several GC cycles and assert that
;; held data survives while throwaways are reclaimed without corruption.

(deftest "container-gc/held-contents-survive-churn"
  (let keep (vector (list 1 2 3) (cons 'a 'b) "held"))
  (let h (make-hash-table))
  (hash-set! h 'x (list 10 20))
  (hash-set! h "s" (vector 7 8 9))
  ;; ~1.2M allocations (cells + throwaway containers) force repeated GC. The
  ;; throwaway vectors/tables become garbage immediately, exercising the GC
  ;; handler; `keep` and `h` are held globals, exercising the mark handler.
  (let i 0)
  (while (< i 400000)
    (cons i i)
    (make-vector 3 i)
    (make-hash-table)
    (set i (+ i 1)))
  ;; held vector contents intact
  (check (equal? (vector-ref keep 0) (list 1 2 3)))
  (check (is (car (vector-ref keep 1)) 'a))
  (check (is (cdr (vector-ref keep 1)) 'b))
  (check (= (vector-ref keep 2) "held"))
  ;; held hash entries intact (including a nested vector value)
  (check (equal? (hash-ref h 'x) (list 10 20)))
  (check (equal? (vector->list (hash-ref h "s")) '(7 8 9))))

(deftest "container-gc/mutated-after-gc"
  ;; A held vector mutated to point at fresh objects after churn must keep them.
  (let v (make-vector 3 nil))
  (let i 0)
  (while (< i 300000)
    (cons i i)
    (set i (+ i 1)))
  (vector-set! v 0 (list 'fresh 1))
  (vector-set! v 1 (list 'fresh 2))
  (set i 0)
  (while (< i 300000)
    (cons i i)
    (set i (+ i 1)))
  (check (equal? (vector-ref v 0) (list 'fresh 1)))
  (check (equal? (vector-ref v 1) (list 'fresh 2)))
  (check (nil? (vector-ref v 2))))
