;; KEC Core §4.5 — def

(deftest "def/defn"
  (defn sq (x) (* x x))
  (check (is (sq 5) 25)))

(deftest "def/defn-variadic"
  (defn sum (a . rest)
    (let s a)
    (while rest (= s (+ s (car rest))) (= rest (cdr rest)))
    s)
  (check (is (sum 1 2 3 4) 10)))

(deftest "def/defmacro"
  (defmacro twice (e) (list 'do e e))
  (= k 0)
  (twice (= k (+ k 1)))
  (check (is k 2)))

(deftest "def/define"
  (define answer 42)
  (check (is answer 42))
  (define (dbl x) (* 2 x))
  (check (is (dbl 21) 42)))
