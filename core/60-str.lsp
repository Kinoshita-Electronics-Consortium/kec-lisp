;; KEC Core — str : string & format
;;
;; The char-level pieces (string-length, string-ref, substring, string-append,
;; number->string, string->number, char->string) are host primitives — Fe gives
;; no way to index a string from Lisp. This module builds the rest on top.

;; (str a b...) -> concatenate stringified args. string-append already
;; stringifies each argument (numbers via %.7g, symbols by name, strings raw).
(set str string-append)

;; (join xs sep) -> elements of xs joined by sep. Iterative (see hof note).
(defn join (xs sep)
  (if (nil? xs)
      ""
      (do
        (let out (str (car xs)))
        (set xs (cdr xs))
        (while xs
          (set out (str out sep (car xs)))
          (set xs (cdr xs)))
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
        (do (set out (cons (substring s start i) out))
            (set start (+ i 1))))
    (set i (+ i 1)))
  (set out (cons (substring s start n) out))
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
          (set i (+ i 1))
          (let d (string-ref fmt i))
          (cond
            ((is d 100) (set out (str out (number->string (car args)))) (set args (cdr args)))     ; d
            ((is d 117) (set out (str out (number->string (car args)))) (set args (cdr args)))     ; u
            ((is d 120) (set out (str out (number->string (car args) 16))) (set args (cdr args)))  ; x
            ((is d 99)  (set out (str out (char->string (car args)))) (set args (cdr args)))       ; c
            ((is d 115) (set out (str out (str (car args)))) (set args (cdr args)))                ; s
            ((is d 37)  (set out (str out "%")))                                                 ; %
            (else (set out (str out "%")) (set out (str out (char->string d))))))
        (set out (str out (char->string c))))
    (set i (+ i 1)))
  out)

;; Character-class predicates over char codes (as returned by string-ref) — the
;; building blocks for word/symbol-boundary scanning (nEmacs, tokenizers).

;; (char-whitespace? c) -> space, tab, newline, or carriage return.
(defn char-whitespace? (c)
  (or (is c 32) (is c 9) (is c 10) (is c 13)))

;; (char-digit? c) -> ASCII '0'..'9'.
(defn char-digit? (c)
  (and (<= 48 c) (<= c 57)))

;; (char-alpha? c) -> ASCII 'A'..'Z' or 'a'..'z'.
(defn char-alpha? (c)
  (or (and (<= 65 c) (<= c 90))
      (and (<= 97 c) (<= c 122))))

;; (char-alphanumeric? c) -> letter or digit.
(defn char-alphanumeric? (c)
  (or (char-alpha? c) (char-digit? c)))
