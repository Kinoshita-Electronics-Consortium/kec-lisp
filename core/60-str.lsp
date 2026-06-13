;; KEC Core — str : string & format (standard §4.6)
;;
;; The char-level leaves (string-length, string-ref, substring,
;; string-append, number->string, string->number, char->string) are host
;; primitives — Fe exposes no way to index a string from Lisp. This module
;; provides the composite forms §4.6 specifies, authored over those leaves.

;; (str a b...) -> concatenate stringified args. string-append already
;; stringifies each argument (numbers via %.7g, symbols by name, strings raw).
(= str string-append)

;; (join xs sep) -> elements of xs joined by sep. Iterative (see hof note).
(defn join (xs sep)
  (if (nil? xs)
      ""
      (do
        (let out (str (car xs)))
        (= xs (cdr xs))
        (while xs
          (= out (str out sep (car xs)))
          (= xs (cdr xs)))
        out)))

;; (split s sep) -> list of substrings of s, split on the first char of sep.
(defn split (s sep)
  (let sepc (string-ref sep 0))
  (let n (string-length s))
  (let out nil)
  (let start 0)
  (let i 0)
  (while (< i n)
    (if (is (string-ref s i) sepc)
        (do (= out (cons (substring s start i) out))
            (= start (+ i 1))))
    (= i (+ i 1)))
  (= out (cons (substring s start n) out))
  (reverse out))

;; (format fmt arg...) -> printf-style splice returning a string.
;; Directives: %d %u (decimal), %x (hex), %c (char code), %s (any), %% (literal).
(defn format (fmt . args)
  (let n (string-length fmt))
  (let out "")
  (let i 0)
  (while (< i n)
    (let c (string-ref fmt i))
    (if (is c 37)                                  ; '%'
        (do
          (= i (+ i 1))
          (let d (string-ref fmt i))
          (cond
            ((is d 100) (= out (str out (number->string (car args)))) (= args (cdr args)))     ; d
            ((is d 117) (= out (str out (number->string (car args)))) (= args (cdr args)))     ; u
            ((is d 120) (= out (str out (number->string (car args) 16))) (= args (cdr args)))  ; x
            ((is d 99)  (= out (str out (char->string (car args)))) (= args (cdr args)))       ; c
            ((is d 115) (= out (str out (str (car args)))) (= args (cdr args)))                ; s
            ((is d 37)  (= out (str out "%")))                                                 ; %
            (else (= out (str out "%")) (= out (str out (char->string d))))))
        (= out (str out (char->string c))))
    (= i (+ i 1)))
  out)
