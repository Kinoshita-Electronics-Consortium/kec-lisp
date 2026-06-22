;; KEC Lisp editor tier — zipper conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")

;; helper: build a buffer from a source string
(defn buf (s) (buffer-from-forms (read-all s)))

;; ---- navigation ----
(deftest "zipper/nav-descend-siblings-ascend"
  (let z (buf "(a b c)"))
  (set z (descend z))
  (check (is (loc-focus z) 'a))
  (set z (next-sibling z))
  (check (is (loc-focus z) 'b))
  (set z (next-sibling z))
  (check (is (loc-focus z) 'c))
  (set z (prev-sibling z))
  (check (is (loc-focus z) 'b))
  (set z (ascend z))
  (check (equal? (loc-focus z) (read-string "(a b c)"))))

(deftest "zipper/descend-to-leaf"
  (let z (buf "((a b) c)"))
  ;; whole buffer focus is the first form ((a b) c); descend-to-leaf -> a
  (set z (descend-to-leaf z))
  (check (is (loc-focus z) 'a)))

(deftest "zipper/multi-top-level"
  (let z (buf "(x) (y) (z)"))
  (check (equal? (loc-focus z) (read-string "(x)")))
  (set z (next-sibling z))
  (check (equal? (loc-focus z) (read-string "(y)")))
  (set z (next-sibling z))
  (check (equal? (loc-focus z) (read-string "(z)")))
  (check (equal? (loc->forms z) (read-all "(x) (y) (z)"))))

;; ---- boundary errors ----
(deftest "zipper/boundaries"
  (let z (buf "(a b)"))
  ;; z is seated on the first top-level form with one crumb frame, so a single
  ;; `ascend` lands on the virtual root (the whole forms list). Ascending AGAIN
  ;; from there is the boundary error.
  (let root (ascend z))                      ; -> forms list, now at-root
  (check (at-root? root))
  (check-err (ascend root))                  ; ascend past root -> err
  (check-err (next-sibling root))            ; at root, no crumbs -> err
  (check-err (prev-sibling root))            ; at root, no crumbs -> err
  (let zz (descend z))                       ; on a
  (check-err (prev-sibling zz))              ; a is first
  (check-err (descend zz))                   ; a is a leaf -> descend err
  (let last (next-sibling zz))               ; on b
  (check-err (next-sibling last)))           ; b is last

;; ---- manipulation ----
(deftest "zipper/insert-leaf"
  (let z (descend (buf "(a c)")))            ; on a
  (set z (insert-leaf z 'b))                 ; insert b after a, cursor on b
  (check (is (loc-focus z) 'b))
  (check (equal? (loc->forms z) (read-all "(a b c)"))))

(deftest "zipper/delete-node"
  (let z (descend (buf "(a b c)")))          ; on a
  (set z (next-sibling z))                   ; on b
  (let r (delete-node z))
  (set z (car r))
  (check (is (cdr r) 'b))                     ; cut is b
  (check (is (loc-focus z) 'c))              ; landed on right sibling
  (check (equal? (loc->forms z) (read-all "(a c)"))))

(deftest "zipper/delete-last-lands-left"
  (let z (descend (buf "(a b c)")))
  (set z (next-sibling z)) (set z (next-sibling z)) ; on c (last)
  (let r (delete-node z))
  (set z (car r))
  (check (is (loc-focus z) 'b))              ; landed on left sibling
  (check (equal? (loc->forms z) (read-all "(a b)"))))

(deftest "zipper/paste"
  (let z (descend (buf "(a c)")))            ; on a
  (set z (paste z (read-string "(x y)")))    ; paste (x y) after a
  (check (equal? (loc-focus z) (read-string "(x y)")))
  (check (equal? (loc->forms z) (read-all "(a (x y) c)"))))

(deftest "zipper/wrap"
  (let z (descend (buf "(a b)")))            ; on a
  (set z (wrap z))                           ; a -> (a), cursor on a inside
  (check (is (loc-focus z) 'a))
  (check (equal? (loc->forms z) (read-all "((a) b)"))))

(deftest "zipper/splice"
  (let z (descend (buf "(a (b c) d)")))      ; on a
  (set z (next-sibling z))                   ; on (b c)
  (set z (splice z))                         ; splice -> a b c d
  (check (is (loc-focus z) 'b))              ; cursor on first spliced child
  (check (equal? (loc->forms z) (read-all "(a b c d)"))))

(deftest "zipper/transpose"
  (let z (descend (buf "(a b c)")))          ; on a
  (set z (transpose z))                      ; swap a,b; cursor stays on a
  (check (is (loc-focus z) 'a))
  (check (equal? (loc->forms z) (read-all "(b a c)"))))

;; ---- well-formedness invariant after a verb sequence ----
(deftest "zipper/invariant-sequence"
  (let z (descend (buf "(a (b c) d)")))
  (set z (next-sibling z))                   ; (b c)
  (set z (wrap z))                           ; ((b c)) ; cursor seated ON (b c)
  (check (buffer-wellformed? z nil))
  (check (equal? (loc->forms z) (read-all "(a ((b c)) d)")))
  (set z (splice z))                         ; splice (b c) into wrapper -> (b c)
  (check (buffer-wellformed? z nil))
  (check (equal? (loc->forms z) (read-all "(a (b c) d)")))
  (set z (insert-leaf z 'z))                 ; cursor on b -> insert z after b
  (check (buffer-wellformed? z nil))
  (check (equal? (loc->forms z) (read-all "(a (b z c) d)"))))

;; ---- UNDO via O(1) snapshot (the zipper's payoff) ----
(deftest "zipper/undo-is-snapshot"
  (let z0 (buf "(a b c)"))
  ;; snapshot is just keeping the value -- O(1), no copy
  (let z1 (descend z0))
  (let z2 (delete-node z1))
  (let after (car z2))
  (check (equal? (loc->forms after) (read-all "(b c)")))
  ;; "undo" = restore the old location value. z0 is untouched (functional).
  (check (equal? (loc->forms z0) (read-all "(a b c)"))))
