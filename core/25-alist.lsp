;; KEC Core — alist : structural equality and association-list records
;;
;; `=` / `is` intentionally keep pair identity semantics. `equal?` is the
;; structural comparator library code reaches for when list contents matter.
;; Alist helpers give scripts a small record-like data shape without adding a
;; new runtime type.

(defn equal? (a b)
  ;; the cdr spine is walked iteratively so long lists cannot exhaust the GC
  ;; stack; recursion only descends into cars, so depth tracks tree nesting.
  (let res nil)
  (let done nil)
  (while (not done)
    (if (is a b)
        (do (set res 1) (set done 1))
        (if (or (atom a) (atom b))
            (set done 1)
            (if (equal? (car a) (car b))
                (do (set a (cdr a)) (set b (cdr b)))
                (set done 1)))))
  res)

(defn get (k alist . default)
  (let p (assoc k alist))
  (if p
      (cdr p)
      (if default (car default) nil)))

(defn has? (k alist)
  (not (not (assoc k alist))))

(defn put (k v alist)
  (let out nil)
  (let done nil)
  (let xs alist)
  (while xs
    (let p (car xs))
    (if (and (not done) (is (car p) k))
        (do
          (set out (cons (cons k v) out))
          (set done 1))
        (set out (cons p out)))
    (set xs (cdr xs)))
  (if done
      (reverse out)
      (cons (cons k v) alist)))

(defn keys (alist)
  (let out nil)
  (while alist
    (set out (cons (car (car alist)) out))
    (set alist (cdr alist)))
  (reverse out))

(defn values (alist)
  (let out nil)
  (while alist
    (set out (cons (cdr (car alist)) out))
    (set alist (cdr alist)))
  (reverse out))

(defn merge (a b)
  (let out a)
  (while b
    (let p (car b))
    (set out (put (car p) (cdr p) out))
    (set b (cdr b)))
  out)
