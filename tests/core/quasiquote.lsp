;; KEC Core — quasiquote reader sugar and expansion.

(deftest "quasiquote/literals"
  (check (equal? `(1 2 3) (list 1 2 3)))
  (check (equal? `foo 'foo))
  (check (equal? `(a (b c)) (list 'a (list 'b 'c)))))

(deftest "quasiquote/unquote"
  (let x 7)
  (check (equal? `(a ,x c) (list 'a 7 'c)))
  (check (equal? `(sum ,(+ 1 2)) (list 'sum 3))))

(deftest "quasiquote/unquote-splicing"
  (let xs (list 2 3))
  (check (equal? `(1 ,@xs 4) (list 1 2 3 4)))
  (check (equal? `(a ,@(list 'b 'c) d) (list 'a 'b 'c 'd))))

(deftest "quasiquote/dotted-unquote-tail"
  ;; `(1 . ,b) reads as (1 unquote b); the spine tail must be spliced, not
  ;; emitted as the literal symbols (1 unquote b).
  (let b (list 2 3))
  (check (equal? `(1 . ,b) (list 1 2 3)))
  (check (equal? `(1 2 . ,b) (list 1 2 2 3)))
  (check (equal? `(,(+ 0 1) . ,b) (list 1 2 3)))
  (check (equal? `(a . ,(+ 1 1)) (cons 'a 2))))

(deftest "quasiquote/nested-raises"
  ;; Nested quasiquote is not supported: it must raise loudly at expansion
  ;; time, never silently substitute inner unquotes one level too early.
  (let c 9)
  (check-err `(a `(b ,c)))
  (check-err ``x)
  (check-err `(a . `b)))

(deftest "quasiquote/dotted-splice-tail-raises"
  ;; ,@ in dotted tail position has no meaning; raise, don't emit litter.
  (let b (list 2 3))
  (check-err `(1 . ,@b)))

(deftest "quasiquote/reserved-symbols"
  ;; unquote/unquote-splicing/quasiquote are reserved inside a template:
  ;; `(a unquote b) is structurally identical to `(a . ,b) after the reader
  ;; runs, so the expander must treat both as the dotted splice. A template
  ;; needing the symbols as data builds the form with list/quote instead.
  (let b (list 2 3))
  (check (equal? `(a unquote b) (cons 'a (list 2 3))))
  (check (equal? (list 'a 'unquote 'b) '(a unquote b))))

(deftest "quasiquote/macro-ergonomics"
  (defmacro qq-when (test . body)
    `(if ,test (do ,@body) nil))
  (let x 0)
  (qq-when 1 (set x 42))
  (check (is x 42)))
