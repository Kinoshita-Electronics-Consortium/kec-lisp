;; KEC Lisp editor tier — undo-ring conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")

(deftest "undo/empty"
  (let r (make-undo-ring 4))
  (check (undo-empty? r))
  (check (is (undo-depth r) 0))
  (check (nil? (undo-pop r)))
  (check (nil? (undo-peek r))))

(deftest "undo/push-peek-depth"
  (let r (make-undo-ring 4))
  (undo-push r 'a)
  (undo-push r 'b)
  (check (is (undo-depth r) 2))
  (check (not (undo-empty? r)))
  (check (is (undo-peek r) 'b))             ; peek doesn't remove
  (check (is (undo-depth r) 2)))

(deftest "undo/pop-is-lifo"
  (let r (make-undo-ring 4))
  (undo-push r 1)
  (undo-push r 2)
  (undo-push r 3)
  (check (is (undo-pop r) 3))
  (check (is (undo-pop r) 2))
  (check (is (undo-pop r) 1))
  (check (undo-empty? r))
  (check (nil? (undo-pop r))))

(deftest "undo/capacity-overflow-drops-oldest"
  (let r (make-undo-ring 3))
  (undo-push r 'v1)
  (undo-push r 'v2)
  (undo-push r 'v3)
  (undo-push r 'v4)                          ; overwrites v1 (oldest)
  (undo-push r 'v5)                          ; overwrites v2
  (check (is (undo-depth r) 3))             ; capped
  (check (is (undo-pop r) 'v5))
  (check (is (undo-pop r) 'v4))
  (check (is (undo-pop r) 'v3))
  (check (undo-empty? r)))                   ; v1, v2 are gone

;; ---- integration: undo a sequence of structural edits ----
;; Push the location BEFORE each edit; undo = pop and restore that snapshot.
(deftest "undo/restores-zipper-edits"
  (let r (make-undo-ring 8))
  (let z (descend (buffer-from-forms (read-all "(a b c d)"))))  ; on a
  (undo-push r z)                            ; snapshot s0 = (a b c d)
  (set z (car (delete-node z)))             ; delete a -> (b c d), on b
  (undo-push r z)                            ; snapshot s1 = (b c d)
  (set z (insert-leaf z 'X))                ; -> (b X c d)
  (check (equal? (loc->forms z) (read-all "(b X c d)")))
  (set z (undo-pop r))                      ; undo -> s1
  (check (equal? (loc->forms z) (read-all "(b c d)")))
  (set z (undo-pop r))                      ; undo -> s0 (original restored)
  (check (equal? (loc->forms z) (read-all "(a b c d)")))
  (check (undo-empty? r)))
