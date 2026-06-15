;; KEC Core §4.5 — def

(deftest "def/defn"
  (defn sq (x) (* x x))
  (check (is (sq 5) 25)))

(deftest "def/defn-variadic"
  (defn sum (a . rest)
    (let s a)
    (while rest (set s (+ s (car rest))) (set rest (cdr rest)))
    s)
  (check (is (sum 1 2 3 4) 10)))

(deftest "def/defmacro"
  (defmacro twice (e) (list 'do e e))
  (set k 0)
  (twice (set k (+ k 1)))
  (check (is k 2)))

(deftest "def/define"
  (define answer 42)
  (check (is answer 42))
  (define (dbl x) (* 2 x))
  (check (is (dbl 21) 42)))

;; The def forms return the thing they defined (not nil) so definitions chain
;; and the REPL echoes something useful. `set` returns nil, so the expansions
;; hand the binding back explicitly.
(deftest "def/defn-returns-fn"
  (check (is (defn ret-f (x) x) ret-f))          ; returns the fn, not nil
  (check (is (ret-f 7) 7)))                       ; and it's bound + callable

(deftest "def/define-returns-value"
  (check (is (define ret-v 99) 99))               ; value form returns the value
  (check (is (define (ret-g x) (* x x)) ret-g)))  ; fn form returns the fn

(deftest "def/defmacro-returns-macro"
  (check (is (defmacro ret-m (e) (list 'do e e)) ret-m)))
