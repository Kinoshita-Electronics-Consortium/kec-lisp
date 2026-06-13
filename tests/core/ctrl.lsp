;; KEC Core §4.4 — ctrl

(deftest "ctrl/when-unless"
  (= a 0)
  (when 1 (= a 5))
  (check (is a 5))
  (unless nil (= a 6))
  (check (is a 6))
  (when nil (= a 99))
  (check (is a 6)))

(deftest "ctrl/cond"
  (defn classify (n)
    (cond ((< n 0) 'neg)
          ((is n 0) 'zero)
          (else 'pos)))
  (check (is (classify -3) 'neg))
  (check (is (classify 0) 'zero))
  (check (is (classify 7) 'pos)))

(deftest "ctrl/case"
  (defn nm (n)
    (case n
      (1 'one)
      ((2 3) 'few)
      (else 'many)))
  (check (is (nm 1) 'one))
  (check (is (nm 3) 'few))
  (check (is (nm 9) 'many)))

(deftest "ctrl/let*"
  (check (is (let* ((a 2) (b (* a 3))) (+ a b)) 8)))

(deftest "ctrl/letrec"
  (letrec ((ev? (fn (n) (if (is n 0) 1 (od? (- n 1)))))
           (od? (fn (n) (if (is n 0) nil (ev? (- n 1))))))
    (check (ev? 10))
    (check (not (ev? 7)))))

(deftest "ctrl/dotimes-dolist"
  (= s 0)
  (dotimes (i 5) (= s (+ s i)))
  (check (is s 10))                 ; 0+1+2+3+4
  (= acc nil)
  (dolist (x (list 1 2 3)) (= acc (cons x acc)))
  (check (is (length acc) 3))
  (check (is (car acc) 3)))

(deftest "ctrl/begin"
  (check (is (begin 1 2 3) 3)))
