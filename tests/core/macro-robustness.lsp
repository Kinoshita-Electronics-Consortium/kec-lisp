;; KEC Core — macro robustness against prelude shadowing.
;;
;; A Core macro must expand into forms that bottom out on FROZEN KERNEL
;; primitives only — never on a shadowable public Core function (member, nth,
;; append, nil?, ...). Otherwise a cart that redefines such a name silently
;; corrupts the macro. AMOP §4.2.2 ("Overriding the Standard Method", pp.
;; 112-113): a protocol must decide which operations may be overridden; the
;; macro substrate is "prohibited-override" in spirit.
;;
;; Prelude helpers are protected globals now: attempted clobbers must raise, and
;; the macro substrate should keep working because the attempted mutation never
;; lands.

(defn %protected-prelude-attempts ()
  (check-err (set nth    (fn (xs i) 'BROKEN)))
  (check-err (set append (fn (a b)  'BROKEN)))
  (check-err (set nil?   (fn (x)    'BROKEN)))
  (check-err (set member (fn (x xs) 'BROKEN)))
  (check-err (set pair?  (fn (x)    'BROKEN)))
  (check-err (set map    (fn (f xs) 'BROKEN))))

(deftest "robustness/case-survives-shadow"
  ;; case once expanded to (member tmp '(vals)); a broken member must not change
  ;; the result. Both a match and the else fall-through are checked.
  (%protected-prelude-attempts)
  (check (is (case 2 (1 'one) ((2 3) 'few) (else 'many)) 'few))
  (check (is (case 9 (1 'one) ((2 3) 'few) (else 'many)) 'many))
  (check (is (case 'b (a 'x) (b 'y) (else 'z)) 'y)))

(deftest "robustness/quasiquote-splice-survives-shadow"
  ;; `,@ splice once expanded to a public `append`; a broken append must not
  ;; corrupt the spliced list.
  (%protected-prelude-attempts)
  (check (equal? (do (let xs (list 2 3)) `(1 ,@xs 4)) (list 1 2 3 4)))
  (check (equal? (do (let xs (list 9)) `(,@xs)) (list 9))))

(deftest "robustness/let-letrec-survive-shadow"
  (%protected-prelude-attempts)
  (check (is (let* ((a 2) (b (* a 3))) (+ a b)) 8))
  (check (is (letrec ((ev? (fn (n) (if (is n 0) 1 (od? (- n 1)))))
                      (od? (fn (n) (if (is n 0) nil (ev? (- n 1))))))
               (ev? 10)) 1))
  (check (is (cond (nil 'a) (else 'b)) 'b)))

(deftest "robustness/loops-survive-shadow"
  (%protected-prelude-attempts)
  (check (is (do (let s 0) (dotimes (i 5) (set s (+ s i))) s) 10))
  (check (is (do (let acc nil)
                 (dolist (x (list 1 2 3)) (set acc (cons x acc)))
                 (length acc)) 3)))

(deftest "robustness/no-residue-after-restore"
  ;; The wrapper restored the prelude: the real helpers work again.
  (check (is (nth (list 'a 'b 'c) 1) 'b))
  (check (equal? (append (list 1) (list 2)) (list 1 2)))
  (check (member 2 (list 1 2 3))))
