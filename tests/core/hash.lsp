;; KEC Lisp — hash-table conformance (ADR-0003).
;; Keys: numbers (by value), symbols (by identity — interned), strings (by
;; content). Pairs and other aggregates are not hashable.

(deftest "hash/empty"
  (let h (make-hash-table))
  (check (hash-table? h))
  (check (is (hash-count h) 0))
  (check (not (hash-has? h 'x)))
  (check (nil? (hash-ref h 'x)))
  (check (is (hash-ref h 'x 42) 42)))    ; default for a missing key

(deftest "hash/set-get-symbol-keys"
  (let h (make-hash-table))
  (check (is (hash-set! h 'a 1) 1))      ; returns the value
  (hash-set! h 'b 2)
  (check (is (hash-ref h 'a) 1))
  (check (is (hash-ref h 'b) 2))
  (check (hash-has? h 'a))
  (check (is (hash-count h) 2)))

(deftest "hash/number-and-string-keys"
  (let h (make-hash-table))
  (hash-set! h 7 'seven)
  (hash-set! h "name" 'value)
  (check (is (hash-ref h 7) 'seven))
  (check (is (hash-ref h "name") 'value)))

(deftest "hash/string-keys-compare-by-content"
  ;; Two distinct string objects with the same content hit the same entry.
  (let h (make-hash-table))
  (hash-set! h "foo" 1)
  (check (is (hash-ref h (string-append "f" "oo")) 1))
  (check (hash-has? h (string-append "fo" "o"))))

(deftest "hash/overwrite-keeps-count"
  (let h (make-hash-table))
  (hash-set! h 'k 1)
  (hash-set! h 'k 2)
  (check (is (hash-ref h 'k) 2))
  (check (is (hash-count h) 1)))

(deftest "hash/delete"
  (let h (make-hash-table))
  (hash-set! h 'a 1)
  (hash-set! h 'b 2)
  (check (is (hash-del! h 'a) t))        ; present -> t
  (check (not (hash-has? h 'a)))
  (check (is (hash-count h) 1))
  (check (nil? (hash-del! h 'a)))        ; absent -> nil
  (check (is (hash-ref h 'b) 2)))        ; survivor intact

(deftest "hash/grow-keeps-all-entries"
  ;; Insert well past the initial capacity to force several rehashes.
  (let h (make-hash-table))
  (let i 0)
  (while (< i 200)
    (hash-set! h i (* i 10))
    (set i (+ i 1)))
  (check (is (hash-count h) 200))
  (check (is (hash-ref h 0) 0))
  (check (is (hash-ref h 137) 1370))
  (check (is (hash-ref h 199) 1990))
  (check (not (hash-has? h 200))))

(deftest "hash/reinsert-after-delete"
  (let h (make-hash-table))
  (hash-set! h 'a 1)
  (hash-del! h 'a)
  (hash-set! h 'a 9)                      ; reuse the tombstone
  (check (is (hash-ref h 'a) 9))
  (check (is (hash-count h) 1)))

(deftest "hash/keys-values-alist"
  (let h (alist->hash '((a . 1) (b . 2) (c . 3))))
  (check (is (hash-count h) 3))
  (check (is (length (hash-keys h)) 3))
  (check (is (length (hash-values h)) 3))
  (check (is (hash-ref h 'b) 2))
  ;; round-trip via hash->alist: every original pair is recoverable
  (let al (hash->alist h))
  (check (is (get 'a al) 1))
  (check (is (get 'c al) 3)))

(deftest "hash/for-each"
  (let h (alist->hash '((a . 1) (b . 2) (c . 3))))
  (let total 0)
  (hash-for-each (fn (k v) (set total (+ total v))) h)
  (check (is total 6)))

(deftest "hash/type-and-key-errors"
  (let h (make-hash-table))
  (check (not (hash-table? 5)))
  (check (not (hash-table? (vector 1))))
  (check-err (hash-ref (vector 1) 'k))   ; not a hash table
  (check-err (hash-set! h '(1 2) 'v))    ; unhashable key (a pair)
  (check-err (hash-ref h (list 1))))     ; unhashable key

(deftest "hash/long-string-keys-are-exact"
  ;; String keys hash and compare by their FULL content — two ~2000-char keys
  ;; sharing a long common prefix are different keys, and a same-content copy
  ;; (a distinct string object) finds the entry. Regression: keys used to be
  ;; compared/hashed over only their first 1024 bytes, silently colliding.
  (let prefix (string-repeat "x" 1990))
  (let k1 (string-append prefix "-key-one"))
  (let k2 (string-append prefix "-key-two"))
  (let k1-copy (string-append prefix "-key-one"))
  (let h (make-hash-table))
  (hash-set! h k1 1)
  (hash-set! h k2 2)
  (check (is (hash-count h) 2))
  (check (is (hash-ref h k1) 1))
  (check (is (hash-ref h k2) 2))
  (check (is (hash-ref h k1-copy) 1))    ; content equality, not identity
  (check (hash-has? h k2))
  (hash-del! h k1)
  (check (nil? (hash-ref h k1)))
  (check (is (hash-ref h k2) 2)))
