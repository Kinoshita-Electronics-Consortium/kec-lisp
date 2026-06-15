;; KEC Core — structural equality and alist helpers.

(deftest "equal?/scalars-and-identity"
  (check (equal? 1 1))
  (check (equal? "deck" "deck"))
  (check (equal? 'a 'a))
  (check (nil? (equal? 'a 'b))))

(deftest "equal?/lists-and-pairs"
  (check (nil? (= (list 1 2) (list 1 2))))       ; = remains identity for pairs
  (check (equal? (list 1 2 (list 3 4))
                 (list 1 2 (list 3 4))))
  (check (equal? (cons 'a (cons 'b 'tail))
                 (cons 'a (cons 'b 'tail))))
  (check (nil? (equal? (list 1 2) (list 1 3)))))

(deftest "alist/get-has-keys-values"
  (let r (list (cons 'name "Ada") (cons 'score 42)))
  (check (is (get 'name r) "Ada"))
  (check (is (get 'missing r "fallback") "fallback"))
  (check (nil? (get 'missing r)))
  (check (has? 'score r))
  (check (nil? (has? 'missing r)))
  (check (equal? (keys r) (list 'name 'score)))
  (check (equal? (values r) (list "Ada" 42))))

(deftest "alist/put-and-merge"
  (let r (list (cons 'name "Ada") (cons 'score 42)))
  (let updated (put 'score 99 r))
  (check (is (get 'score updated) 99))
  (check (is (get 'score r) 42))                  ; non-destructive
  (let added (put 'rank 1 r))
  (check (is (get 'rank added) 1))
  (let merged (merge r (list (cons 'score 7) (cons 'rank 1))))
  (check (is (get 'name merged) "Ada"))
  (check (is (get 'score merged) 7))
  (check (is (get 'rank merged) 1)))
