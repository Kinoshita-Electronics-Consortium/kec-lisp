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
