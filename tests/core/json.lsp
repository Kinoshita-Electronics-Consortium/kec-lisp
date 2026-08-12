;; KEC Lisp — JSON reader/writer conformance (core/68-json.lsp).
;;
;; Covers the type mapping, every escape form the RFC defines, the false/null
;; conflation, malformed input, nesting deep enough to break a recursive parser,
;; and the single-precision boundary. The precision tests PIN CURRENT BEHAVIOR:
;; if fe_Number ever stops being a C `float`, they fail, which is the point.

;; --- type mapping -------------------------------------------------------

(deftest "json/scalars"
  (check (is (json-parse "1") 1))
  (check (is (json-parse "-2.5") -2.5))
  (check (is (json-parse "0") 0))
  (check (is (json-parse "1e3") 1000))
  (check (is (json-parse "12.5e-2") 0.125))
  (check (is (json-parse "-0.5e+1") -5))
  (check (is (json-parse "\"hi\"") "hi"))
  (check (is (json-parse "\"\"") ""))
  (check (is (json-parse "true") t))
  (check (nil? (json-parse "false")))
  (check (nil? (json-parse "null")))
  ;; leading/trailing whitespace of every JSON flavor is skipped
  (check (is (json-parse " \t\r\n 7 \t\r\n ") 7)))

(deftest "json/arrays"
  (check (equal? (json-parse "[1,2,3]") (list 1 2 3)))
  (check (equal? (json-parse " [ 1 , 2 ] ") (list 1 2)))
  (check (nil? (json-parse "[]")))
  (check (equal? (json-parse "[[1],[2,[3]]]")
                 (list (list 1) (list 2 (list 3)))))
  ;; mixed element types, in order
  (check (equal? (json-parse "[1,\"a\",true,null,false]")
                 (list 1 "a" t nil nil))))

(deftest "json/objects"
  (let o (json-parse "{\"a\":1,\"b\":\"two\",\"c\":[3]}"))
  (check (hash-table? o))
  (check (is (hash-count o) 3))
  (check (is (hash-ref o "a") 1))
  (check (is (hash-ref o "b") "two"))
  (check (equal? (hash-ref o "c") (list 3)))
  (check (is (hash-count (json-parse "{}")) 0))
  (check (is (hash-count (json-parse " {  } ")) 0))
  ;; nested objects reachable through the outer one
  (let n (json-parse "{\"outer\":{\"inner\":42}}"))
  (check (is (hash-ref (hash-ref n "outer") "inner") 42)))

;; The conflation the module documents: false and null both land on nil,
;; because nil is the only false value in the language. hash-has? is how a
;; caller tells "absent" from "present and null".
(deftest "json/false-null-conflation"
  (let o (json-parse "{\"f\":false,\"n\":null}"))
  (check (nil? (hash-ref o "f")))
  (check (nil? (hash-ref o "n")))
  (check (hash-has? o "f"))
  (check (hash-has? o "n"))
  (check (nil? (hash-has? o "missing")))
  ;; and the values are indistinguishable from each other
  (check (is (hash-ref o "f") (hash-ref o "n"))))

;; A JSON string is never coerced to a number. The Artifacts API returns
;; identifiers like this one, and string->number on it silently yields 6.
(deftest "json/strings-are-never-numbers"
  (let o (json-parse "{\"id\":\"6a75cffcf2928a45b1993f68\",\"n\":\"42\"}"))
  (check (string? (hash-ref o "id")))
  (check (is (hash-ref o "id") "6a75cffcf2928a45b1993f68"))
  (check (string? (hash-ref o "n")))
  (check (is (hash-ref o "n") "42"))
  (check (nil? (number? (hash-ref o "n")))))

;; --- escapes ------------------------------------------------------------

(deftest "json/escapes-short-forms"
  (check (is (json-parse "\"a\\\"b\"") (str "a" (char->string 34) "b")))
  (check (is (json-parse "\"a\\\\b\"") (str "a" (char->string 92) "b")))
  (check (is (json-parse "\"a\\/b\"") "a/b"))
  (check (is (json-parse "\"\\b\"") (char->string 8)))
  (check (is (json-parse "\"\\f\"") (char->string 12)))
  (check (is (json-parse "\"\\n\"") (char->string 10)))
  (check (is (json-parse "\"\\r\"") (char->string 13)))
  (check (is (json-parse "\"\\t\"") (char->string 9)))
  ;; all eight in one string, plus surrounding literal text
  (check (is (string-length (json-parse "\"x\\\"\\\\\\/\\b\\f\\n\\r\\ty\"")) 10)))

(deftest "json/escapes-unicode"
  ;; ASCII via \u
  (check (is (json-parse "\"\\u0041\"") "A"))
  ;; 2-byte UTF-8 (U+00E9 e-acute)
  (let e (json-parse "\"\\u00e9\""))
  (check (is (string-length e) 2))
  (check (is (string-ref e 0) 195))
  (check (is (string-ref e 1) 169))
  ;; 3-byte UTF-8 (U+20AC euro), uppercase hex digits too
  (let eu (json-parse "\"\\u20AC\""))
  (check (is (string-length eu) 3))
  (check (is (string-ref eu 0) 226))
  (check (is (string-ref eu 1) 130))
  (check (is (string-ref eu 2) 172))
  ;; 4-byte UTF-8 from a surrogate pair (U+1F600 grinning face)
  (let g (json-parse "\"\\ud83d\\ude00\""))
  (check (is (string-length g) 4))
  (check (is (string-ref g 0) 240))
  (check (is (string-ref g 1) 159))
  (check (is (string-ref g 2) 152))
  (check (is (string-ref g 3) 128))
  ;; the same code point survives a round trip through the writer
  (check (is (json-parse (json-stringify g)) g)))

(deftest "json/escapes-rejected"
  (check-err (json-parse "\"\\q\""))            ; not an escape
  (check-err (json-parse "\"\\u00\""))          ; truncated \u
  (check-err (json-parse "\"\\u00zz\""))        ; non-hex digits
  (check-err (json-parse "\"\\ud83d\""))        ; unpaired high surrogate
  (check-err (json-parse "\"\\ud83dx\""))       ; high surrogate, no pair follows
  (check-err (json-parse "\"\\ud83d\\u0041\"")) ; high surrogate, bad low
  (check-err (json-parse "\"\\ude00\""))        ; unpaired low surrogate
  ;; U+0000 has no representation in a NUL-terminated string, so it raises
  ;; rather than silently truncating the value
  (check-err (json-parse "\"\\u0000\""))
  ;; a raw control byte must be escaped
  (check-err (json-parse (str "\"a" (char->string 10) "b\""))))

;; --- writer -------------------------------------------------------------

(deftest "json/stringify-scalars"
  (check (is (json-stringify 1) "1"))
  (check (is (json-stringify -2.5) "-2.5"))
  (check (is (json-stringify "hi") "\"hi\""))
  (check (is (json-stringify t) "true"))
  ;; nil is false, null, AND the empty list, and it encodes as null
  (check (is (json-stringify nil) "null")))

(deftest "json/stringify-escapes"
  (check (is (json-stringify (char->string 10)) "\"\\n\""))
  (check (is (json-stringify (char->string 9)) "\"\\t\""))
  (check (is (json-stringify (char->string 8)) "\"\\b\""))
  (check (is (json-stringify (char->string 12)) "\"\\f\""))
  (check (is (json-stringify (char->string 13)) "\"\\r\""))
  (check (is (json-stringify (char->string 34)) "\"\\\"\""))
  (check (is (json-stringify (char->string 92)) "\"\\\\\""))
  ;; other control bytes take the \u00XX long form, zero-padded
  (check (is (json-stringify (char->string 1)) "\"\\u0001\""))
  (check (is (json-stringify (char->string 31)) "\"\\u001f\""))
  ;; a forward slash needs no escape on the way out
  (check (is (json-stringify "a/b") "\"a/b\"")))

(deftest "json/stringify-composites"
  (check (is (json-stringify (list 1 2)) "[1,2]"))
  (check (is (json-stringify (list "a" t nil)) "[\"a\",true,null]"))
  (check (is (json-stringify (list (list 1) (list 2))) "[[1],[2]]"))
  (let h (make-hash-table))
  (check (is (json-stringify h) "{}"))
  (hash-set! h "k" 7)
  (check (is (json-stringify h) "{\"k\":7}")))

(deftest "json/stringify-rejects"
  (check-err (json-stringify 'sym))             ; a symbol has no JSON spelling
  (check-err (json-stringify (make-vector 2 0)))
  (check-err (json-stringify (fn (x) x)))
  ;; a non-string object key cannot be written
  (let h (make-hash-table))
  (hash-set! h 1 "one")
  (check-err (json-stringify h)))

;; --- round trips --------------------------------------------------------

(deftest "json/round-trip"
  (let src "{\"name\":\"copper_ore\",\"qty\":12,\"tags\":[\"ore\",\"raw\"],\"ok\":true,\"note\":null}")
  (let a (json-parse src))
  (let b (json-parse (json-stringify a)))
  (check (is (hash-count b) 5))
  (check (is (hash-ref b "name") "copper_ore"))
  (check (is (hash-ref b "qty") 12))
  (check (equal? (hash-ref b "tags") (list "ore" "raw")))
  (check (is (hash-ref b "ok") t))
  (check (nil? (hash-ref b "note")))
  ;; ... but `null` came back for what was `null`, and false would too
  (check (hash-has? b "note")))

(deftest "json/round-trip-nested-lists"
  (let v (list 1 (list 2 (list 3 (list 4))) "x"))
  (check (equal? (json-parse (json-stringify v)) v)))

;; --- malformed input ----------------------------------------------------

(deftest "json/malformed"
  (check-err (json-parse ""))                   ; empty input
  (check-err (json-parse "   "))
  (check-err (json-parse "["))                  ; unclosed array
  (check-err (json-parse "{"))                  ; unclosed object
  (check-err (json-parse "[1,]"))               ; trailing comma
  (check-err (json-parse "{\"a\":1,}"))
  (check-err (json-parse "[1 2]"))              ; missing comma
  (check-err (json-parse "{\"a\" 1}"))          ; missing colon
  (check-err (json-parse "{a:1}"))              ; unquoted key
  (check-err (json-parse "{1:2}"))              ; non-string key
  (check-err (json-parse "\"abc"))              ; unterminated string
  (check-err (json-parse "[1,2] junk"))         ; trailing content
  (check-err (json-parse "tru"))                ; truncated literal
  (check-err (json-parse "nul"))
  (check-err (json-parse "01"))                 ; leading zero
  (check-err (json-parse "-"))                  ; sign with no digits
  (check-err (json-parse ".5"))                 ; no integer part
  (check-err (json-parse "1."))                 ; no fraction digits
  (check-err (json-parse "1e"))                 ; no exponent digits
  (check-err (json-parse "1e+"))
  (check-err (json-parse "]"))                  ; a closer with nothing open
  (check-err (json-parse 42)))                  ; not a string at all

;; Every parse error names the byte offset, so a failure in a 30 KB API
;; response can be located instead of guessed at.
(deftest "json/error-messages-carry-the-offset"
  (let e (try (fn () (json-parse "[1,2,x]"))))
  (check (error? e))
  (check (string-contains? (error-message e) "byte 5"))
  (let e2 (try (fn () (json-parse "{\"a\":1 \"b\":2}"))))
  (check (error? e2))
  (check (string-contains? (error-message e2) "byte "))
  ;; and the message says it came from json-parse
  (check (string-prefix? (error-message e) "json-parse:")))

;; --- depth --------------------------------------------------------------

;; 400 levels of nesting. A recursive-descent parser would consume 400+ GC
;; roots here and die on the device's 256-slot stack; the explicit vector stack
;; costs heap instead.
(deftest "json/deep-nesting-arrays"
  (let depth 400)
  (let src (str (string-repeat "[" depth) "7" (string-repeat "]" depth)))
  (let v (json-parse src))
  (let d 0)
  (while (pair? v)
    (set v (car v))
    (set d (+ d 1)))
  (check (is d depth))
  (check (is v 7)))

(deftest "json/deep-nesting-objects"
  (let depth 200)
  (let src (str (string-repeat "{\"k\":" depth) "1" (string-repeat "}" depth)))
  (let v (json-parse src))
  (let d 0)
  (while (hash-table? v)
    (set v (hash-ref v "k"))
    (set d (+ d 1)))
  (check (is d depth))
  (check (is v 1)))

;; The writer is iterative too, so it survives what the reader produces.
(deftest "json/deep-nesting-stringify"
  (let depth 300)
  (let v 7)
  (let i 0)
  (while (< i depth)
    (set v (list v))
    (set i (+ i 1)))
  (let out (json-stringify v))
  (check (is (string-length out) (+ (* 2 depth) 1)))
  (check (string-prefix? out "[[[")))

;; A wide document (many siblings rather than deep nesting) exercises the
;; batched string assembly on both sides.
(deftest "json/wide-array"
  (let xs (range 0 500))
  (let out (json-stringify xs))
  (check (equal? (json-parse out) xs)))

;; --- single-precision boundary ------------------------------------------

;; fe_Number is a C float (kernel/fe.h line 16), so integers are exact only to
;; 2^24. These pin the current behavior: change the number type and they fail.
(deftest "json/float32-precision-ceiling"
  ;; exact at and below 2^24
  (check (is (json-parse "16777216") 16777216))
  (check (is (json-parse "1000000") 1000000))
  (check (is (json-parse "-16777216") -16777216))
  ;; 2^24 + 1 is NOT representable and collapses onto 2^24
  (check (is (json-parse "16777217") 16777216))
  (check (is (json-parse "16777217") (json-parse "16777216")))
  ;; a 64-bit-style identifier as a number loses its low digits entirely: two
  ;; ids one apart decode to the same value, which is why API ids must stay
  ;; strings
  (check (is (json-parse "9007199254740993") (json-parse "9007199254740992")))
  ;; epoch seconds are already past the exact range: two timestamps a second
  ;; apart are the same number, so timestamp arithmetic is unsafe
  (check (is (json-parse "1786000000") (json-parse "1786000001")))
  ;; ... which is why an ISO 8601 timestamp stays a string and compares
  ;; lexically instead: for a fixed-width UTC stamp, byte order IS chronological
  ;; order, and the comparison never touches a float
  (let a "2026-08-11T09:00:00Z")
  (let b "2026-08-11T09:00:01Z")
  (check (string? (json-parse (str "\"" a "\""))))
  (check (< (string-ref a 18) (string-ref b 18))))

(deftest "json/number-values-out-of-range"
  ;; a number too large for a float becomes an infinity on the way in, and an
  ;; infinity has no JSON spelling on the way out
  (check-err (json-stringify (json-parse "1e40"))))
