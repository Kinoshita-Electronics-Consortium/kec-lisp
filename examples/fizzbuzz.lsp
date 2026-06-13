;; FizzBuzz — exercises dotimes, cond, mod, and number->string.
(defn fizzbuzz (n)
  (dotimes (i n)
    (let k (+ i 1))
    (princ
      (cond ((is (mod k 15) 0) "FizzBuzz")
            ((is (mod k 3)  0) "Fizz")
            ((is (mod k 5)  0) "Buzz")
            (else (number->string k))))
    (newline)))

(fizzbuzz 15)
