;; KEC Lisp editor tier — token ranker conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/80-ranker.lsp")

;; a small static vocabulary: (name . category)
(defn sample-cands ()
  (list (cons "map" 'function) (cons "filter" 'function)
        (cons "foldl" 'function) (cons "car" 'function)
        (cons "xs" 'binding) (cons "acc" 'binding)))

;; index: map/filter/foldl are domain vocab (+5); map pop 4, filter pop 2;
;; car/cdr are builtins (never suggested).
(defn sample-idx ()
  (ranker-index (list "map" "filter" "foldl")
                (list (cons "map" 4) (cons "filter" 2))
                (list "car" "cdr")))

(deftest "ranker/function-position-order"
  (let r (rank-tokens (sample-cands) (ranker-context 'function nil nil nil) (sample-idx)))
  ;; car excluded (builtin); xs/acc illegal at a function position.
  ;; map = 5+4 = 9, filter = 5+2 = 7, foldl = 5.
  (check (equal? r (list "map" "filter" "foldl"))))

(deftest "ranker/never-shadows-a-builtin"
  (let r (rank-tokens (sample-cands) (ranker-context 'function nil nil nil) (sample-idx)))
  (check (not (member "car" r))))

(deftest "ranker/legal-position-filter"
  ;; bindings are illegal at a function position, legal at an argument position.
  (let fn-r  (rank-tokens (sample-cands) (ranker-context 'function nil nil nil) (sample-idx)))
  (let arg-r (rank-tokens (sample-cands) (ranker-context 'argument nil nil nil) (sample-idx)))
  (check (not (member "xs" fn-r)))
  (check (member "xs" arg-r)))

(deftest "ranker/alphabetic-tiebreak"
  (let cands (list (cons "beta" 'function) (cons "alpha" 'function)))
  (let idx (ranker-index (list "alpha" "beta") nil nil))  ; both +5, equal score
  (let r (rank-tokens cands (ranker-context 'function nil nil nil) idx))
  (check (equal? r (list "alpha" "beta"))))               ; earlier name wins ties

(deftest "ranker/recency-boost"
  ;; foldl used most recently -> +10 recency -> 15, tops map's 9.
  (let ctx (ranker-context 'function (list "foldl") nil nil))
  (let r (rank-tokens (sample-cands) ctx (sample-idx)))
  (check (= (car r) "foldl")))

(deftest "ranker/local-binding-boost"
  ;; xs as an in-scope local (+3) outranks acc (0) at an argument position.
  (let ctx (ranker-context 'argument nil (list "xs") nil))
  (let scored (rank (sample-cands) ctx (sample-idx)))
  (let xs-entry (find (fn (e) (= (cdr e) "xs")) scored))
  (check (is (car xs-entry) 3)))

(deftest "ranker/top-8-bound"
  (let many (map (fn (i) (cons (string-append "f" (number->string i)) 'function))
                 (range 0 12)))                            ; 12 candidates
  (let idx (ranker-index (map car many) nil nil))          ; all +5, equal
  (let r (rank-tokens many (ranker-context 'function nil nil nil) idx))
  (check (is (length r) 8)))                               ; capped at top-8

(deftest "ranker/semantic-fit-and-popularity"
  (let cands (list (cons "alpha" 'function) (cons "beta" 'function)))
  ;; alpha: vocab+5, pop+3 = 8 ; beta: vocab+5, semfit+1 = 6
  (let idx (ranker-index (list "alpha" "beta") (list (cons "alpha" 3)) nil))
  (let ctx (ranker-context 'function nil nil (list "beta")))  ; beta semantically fits
  (let r (rank-tokens cands ctx idx))
  (check (equal? r (list "alpha" "beta"))))
