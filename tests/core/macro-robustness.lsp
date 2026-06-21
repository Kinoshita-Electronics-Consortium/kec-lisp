;; KEC Core — macro robustness against prelude shadowing.
;;
;; A Core macro must expand into forms that bottom out on FROZEN KERNEL
;; primitives only — never on a shadowable public Core function (member, nth,
;; append, nil?, ...). Otherwise a cart that redefines such a name silently
;; corrupts the macro. AMOP §4.2.2 ("Overriding the Standard Method", pp.
;; 112-113): a protocol must decide which operations may be overridden; the
;; macro substrate is "prohibited-override" in spirit.
;;
;; `%with-broken-prelude` clobbers the public list helpers GLOBALLY, runs a
;; thunk (so the macro inside expands AND evaluates under the broken prelude —
;; expansion happens at call time), then ALWAYS restores via try. If a macro
;; touched any clobbered name — at expand time or in its emitted code — the
;; result would be wrong.

(set %wbp-saved nil)
(defn %with-broken-prelude (thunk)
  (let s-nth nth) (let s-append append) (let s-nil? nil?)
  (let s-member member) (let s-pair? pair?) (let s-map map)
  (set nth    (fn (xs i) 'BROKEN))
  (set append (fn (a b)  'BROKEN))
  (set nil?   (fn (x)    'BROKEN))
  (set member (fn (x xs) 'BROKEN))
  (set pair?  (fn (x)    'BROKEN))
  (set map    (fn (f xs) 'BROKEN))
  (let result (try thunk))        ; try calls (thunk) under a guard, always returns
  (set nth s-nth) (set append s-append) (set nil? s-nil?)
  (set member s-member) (set pair? s-pair?) (set map s-map)
  result)

(deftest "robustness/case-survives-shadow"
  ;; case once expanded to (member tmp '(vals)); a broken member must not change
  ;; the result. Both a match and the else fall-through are checked.
  (check (is (%with-broken-prelude
               (fn () (case 2 (1 'one) ((2 3) 'few) (else 'many)))) 'few))
  (check (is (%with-broken-prelude
               (fn () (case 9 (1 'one) ((2 3) 'few) (else 'many)))) 'many))
  (check (is (%with-broken-prelude
               (fn () (case 'b (a 'x) (b 'y) (else 'z)))) 'y)))

(deftest "robustness/quasiquote-splice-survives-shadow"
  ;; `,@ splice once expanded to a public `append`; a broken append must not
  ;; corrupt the spliced list.
  (check (equal? (%with-broken-prelude
                   (fn () (let xs (list 2 3)) `(1 ,@xs 4)))
                 (list 1 2 3 4)))
  (check (equal? (%with-broken-prelude
                   (fn () (let xs (list 9)) `(,@xs)))
                 (list 9))))

(deftest "robustness/let-letrec-survive-shadow"
  (check (is (%with-broken-prelude
               (fn () (let* ((a 2) (b (* a 3))) (+ a b)))) 8))
  (check (is (%with-broken-prelude
               (fn () (letrec ((ev? (fn (n) (if (is n 0) 1 (od? (- n 1)))))
                               (od? (fn (n) (if (is n 0) nil (ev? (- n 1))))))
                        (ev? 10)))) 1))
  (check (is (%with-broken-prelude (fn () (cond (nil 'a) (else 'b)))) 'b)))

(deftest "robustness/loops-survive-shadow"
  (check (is (%with-broken-prelude
               (fn () (let s 0) (dotimes (i 5) (set s (+ s i))) s)) 10))
  (check (is (%with-broken-prelude
               (fn () (let acc nil)
                      (dolist (x (list 1 2 3)) (set acc (cons x acc)))
                      (length acc))) 3)))

(deftest "robustness/no-residue-after-restore"
  ;; The wrapper restored the prelude: the real helpers work again.
  (check (is (nth (list 'a 'b 'c) 1) 'b))
  (check (equal? (append (list 1) (list 2)) (list 1 2)))
  (check (member 2 (list 1 2 3))))
