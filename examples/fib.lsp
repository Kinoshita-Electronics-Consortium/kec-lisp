;; Recursion + higher-order composition.
(defn fib (n)
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))

(princ "fib 0..14: ")
(princ (join (map (fn (n) (number->string (fib n))) (range 0 15)) " "))
(newline)
