;; KEC Core §4.6 — str

(deftest "str/str"
  (check (is (str "ab" "cd") "abcd"))
  (check (is (str "n=" 5) "n=5"))           ; numbers stringify
  (check (is (str "a" "b" "c") "abc")))

(deftest "str/join"
  (check (is (join (list "a" "b" "c") "-") "a-b-c"))
  (check (is (join (list "x") "-") "x"))
  (check (is (join nil "-") "")))

(deftest "str/split"
  (let parts (split "a,bb,ccc" ","))
  (check (is (length parts) 3))
  (check (is (nth parts 0) "a"))
  (check (is (nth parts 2) "ccc")))

;; string-split — the char-level primitive (sibling of string-ref): one O(n)
;; pass splitting on a byte code, so Core split / %split-lines aren't O(n^2).
;; N separators yield N+1 segments; always at least one element.
(deftest "str/string-split"
  (let p (string-split "a,bb,ccc" 44))            ; ',' = 44
  (check (is (length p) 3))
  (check (is (nth p 0) "a"))
  (check (is (nth p 1) "bb"))
  (check (is (nth p 2) "ccc"))
  (let e (string-split "" 44))                    ; "" -> ("")
  (check (is (length e) 1))
  (check (is (nth e 0) ""))
  (let tr (string-split "a," 44))                 ; trailing sep -> ("a" "")
  (check (is (length tr) 2))
  (check (is (nth tr 1) ""))
  (let ld (string-split ",a" 44))                 ; leading sep -> ("" "a")
  (check (is (length ld) 2))
  (check (is (nth ld 0) ""))
  (check (is (nth ld 1) "a"))
  (let no (string-split "abc" 44))                ; no sep -> whole string
  (check (is (length no) 1))
  (check (is (nth no 0) "abc"))
  (let ss (string-split ",," 44))                 ; only seps -> ("" "" "")
  (check (is (length ss) 3)))

(deftest "str/format"
  (check (is (format "%d-%d" 1 2) "1-2"))
  (check (is (format "%s!" "hi") "hi!"))
  (check (is (format "%x" 255) "ff"))
  (check (is (format "100%%") "100%"))
  (check (is (string-ref (format "%c" 65) 0) 65)))   ; 'A'

(deftest "str/convert"
  (check (is (string->number "42") 42))
  (check (is (number->string 42) "42"))
  (check (is (string-length "hello") 5))
  (check (nil? (string->number "abc"))))

(deftest "str/search"
  (check (is (string-search "forward-char" "-") 7))   ; first index of needle
  (check (is (string-search "hello" "lo") 3))
  (check (is (string-search "abc" "abc") 0))          ; whole-string match
  (check (nil? (string-search "abc" "z")))            ; absent -> nil
  (check (is (string-search "aXbXc" "X") 1)))         ; first occurrence only

(deftest "str/char-predicates"
  ;; operate on char codes (as returned by string-ref)
  (check (char-whitespace? 32))           ; space
  (check (char-whitespace? 10))           ; newline
  (check (nil? (char-whitespace? 65)))    ; 'A'
  (check (char-alpha? 65))                ; 'A'
  (check (char-alpha? 122))               ; 'z'
  (check (nil? (char-alpha? 48)))         ; '0'
  (check (char-digit? 48))                ; '0'
  (check (char-digit? 57))                ; '9'
  (check (nil? (char-digit? 65)))         ; 'A'
  (check (char-alpha? (string-ref "x" 0))))
