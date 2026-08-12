;; KEC Core — strtool : string/char toolkit (ADR-0001 C).

(deftest "strtool/char-case"
  (check (is (char-upcase 97) 65))     ; 'a' -> 'A'
  (check (is (char-downcase 65) 97))   ; 'A' -> 'a'
  (check (is (char-upcase 65) 65))     ; already upper, unchanged
  (check (is (char-downcase 97) 97))   ; already lower, unchanged
  (check (is (char-upcase 48) 48))     ; '0' non-alpha passthrough
  (check (is (char-downcase 33) 33)))  ; '!' non-alpha passthrough

(deftest "strtool/string-case"
  (check (is (string-upcase "abc") "ABC"))
  (check (is (string-downcase "ABC") "abc"))
  (check (is (string-upcase "a1!b") "A1!B"))   ; non-alpha pass through
  (check (is (string-downcase "X9?Y") "x9?y"))
  (check (is (string-upcase "") ""))           ; empty
  (check (is (string-downcase "") "")))

(deftest "strtool/pad"
  (check (is (pad-left "7" 3) "  7"))          ; shorter -> pad
  (check (is (pad-right "7" 3) "7  "))
  (check (is (pad-left "abc" 3) "abc"))        ; equal -> unchanged
  (check (is (pad-right "abc" 3) "abc"))
  (check (is (pad-left "abcde" 3) "abcde"))    ; longer -> NO truncation
  (check (is (pad-right "abcde" 3) "abcde"))
  (check (is (pad-left "5" 4 "0") "0005"))     ; custom pad char
  (check (is (pad-right "5" 4 "*") "5***"))
  (check-err (pad-left "x" 3 ""))               ; pad is exactly one char
  (check-err (pad-right "x" 3 "ab")))

(deftest "strtool/string-repeat"
  (check (is (string-repeat "ab" 3) "ababab")) ; n > 0
  (check (is (string-repeat "ab" 1) "ab"))     ; n = 1
  (check (is (string-repeat "ab" 0) ""))       ; n = 0
  (check (is (string-repeat "ab" -2) "")))     ; n < 0

(deftest "strtool/prefix-suffix"
  (check (string-prefix? "forward-char" "forward"))   ; true
  (check (nil? (string-prefix? "forward" "back")))    ; false
  (check (string-prefix? "abc" ""))                   ; empty affix -> true
  (check (nil? (string-prefix? "ab" "abcd")))         ; affix longer -> false
  (check (string-suffix? "filename.txt" ".txt"))      ; true
  (check (nil? (string-suffix? "file" ".txt")))       ; false
  (check (string-suffix? "abc" ""))                   ; empty affix -> true
  (check (nil? (string-suffix? "ab" "xab"))))         ; affix longer -> false

(deftest "strtool/contains"
  (check (string-contains? "hello world" "o w"))      ; present
  (check (nil? (string-contains? "hello" "z")))       ; absent
  (check (string-contains? "hello" "")))              ; empty -> true

;; string-concat is the general "assemble a string from many pieces" helper the
;; JSON writer and the HTTP request builder both use, so the interesting cases
;; are the batch boundary (8) and lists far past it.
(deftest "strtool/string-concat"
  (check (is (string-concat nil) ""))                 ; empty list -> ""
  (check (is (string-concat (list "a")) "a"))         ; single element
  (check (is (string-concat (list "a" "b" "c")) "abc"))
  (check (is (string-concat (list "" "" "")) ""))
  ;; exactly the batch size, and one either side of it
  (check (is (string-concat (list "1" "2" "3" "4" "5" "6" "7")) "1234567"))
  (check (is (string-concat (list "1" "2" "3" "4" "5" "6" "7" "8")) "12345678"))
  (check (is (string-concat (list "1" "2" "3" "4" "5" "6" "7" "8" "9")) "123456789"))
  ;; non-strings are stringified the way `str` renders them, including when
  ;; the list has only one element
  (check (is (string-concat (list 1 "-" 2)) "1-2"))
  (check (is (string-concat (list 42)) "42"))
  ;; far past the batch size: 500 pieces, several collapse passes
  (let xs (map (fn (i) "x") (range 0 500)))
  (check (is (string-length (string-concat xs)) 500))
  ;; order is preserved across the passes
  (let ys (map (fn (i) (number->string i)) (range 0 100)))
  (check (string-prefix? (string-concat ys) "012345678910"))
  (check (string-suffix? (string-concat ys) "979899")))
