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
