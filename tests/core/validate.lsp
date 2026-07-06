;; KEC Core — integer-input validation across the host surface (GWP-584).
;;
;; The container / bitwise / RNG APIs already reject fractional, non-finite,
;; or out-of-range numbers (GWP-235). These cover the string-level and system
;; primitives that postdate that sweep: every float->int narrowing must raise
;; a catchable error instead of silently truncating (or hitting the undefined
;; float->int cast). Valid in-range calls keep their exact prior results.
;;
;; NaN is spelled (/ 0 0) and infinity (/ 1 0) — Fe arithmetic is plain IEEE
;; float with no division guard, so both are ordinary numbers here.

(deftest "validate/string-ref"
  (check (is (string-ref "abc" 1) 98))
  (check (nil? (string-ref "abc" -1)))          ; out-of-range integers stay nil
  (check (nil? (string-ref "abc" 3)))
  (check-err (string-ref "abc" 1.5))            ; fractional index
  (check-err (string-ref "abc" (/ 0 0)))        ; NaN index
  (check-err (string-ref "abc" (/ 1 0))))       ; infinite index

(deftest "validate/substring"
  (check (is (substring "hello" 1 3) "el"))
  (check (is (substring "hello" -5 99) "hello")) ; integer clamping preserved
  (check (is (substring "hello" 4 2) ""))        ; end < start clamps empty
  (check-err (substring "hello" 0.5 3))
  (check-err (substring "hello" 0 (/ 0 0))))

(deftest "validate/string-split"
  (check (is (car (string-split "a,b" 44)) "a"))
  (check (is (car (cdr (string-split "a,b" 44))) "b"))
  (check-err (string-split "a,b" 1.5))          ; fractional separator code
  (check-err (string-split "a,b" 256))          ; separator is a byte 0..255
  (check-err (string-split "a,b" -1)))

(deftest "validate/char->string"
  (check (is (char->string 97) "a"))
  (check-err (char->string 97.5))               ; fractional code
  (check-err (char->string 256))                ; code is a byte 0..255
  (check-err (char->string -1)))

(deftest "validate/number->string-radix"
  (check (is (number->string 255 16) "ff"))
  (check (is (number->string 255 2) "11111111"))
  (check (is (number->string -255 16) "-ff"))
  (check (is (number->string 255) "255"))
  (check (is (number->string 2.5) "2.5"))       ; radix 10 keeps fractions
  (check-err (number->string 255 1))            ; radix below 2
  (check-err (number->string 255 17))           ; radix above 16
  (check-err (number->string 255 8.5))          ; fractional radix
  (check-err (number->string 3.7 16)))          ; non-integral value, radix /= 10

(deftest "validate/number->string-int32-min"
  ;; INT32_MIN passes the range gate; its magnitude must be computed in
  ;; unsigned arithmetic — negating the signed value is undefined behavior
  ;; where long is 32 bits (the armhf device target).
  (check (is (number->string -2147483648 16) "-80000000"))
  (check (is (number->string -2147483648 2)
             "-10000000000000000000000000000000")))

(deftest "validate/rand-int-domain"
  (set-seed! 7)
  (let v (rand-int 10))
  (check (and (<= 0 v) (< v 10)))
  (check-err (rand-int 0))                      ; [0,0) is empty — no silent 0
  (check-err (rand-int -3)))
