;; KEC Core — json : a JSON reader and writer, written in KEC Lisp
;;
;;   (json-parse string)     -> the decoded value
;;   (json-stringify value)  -> a JSON string
;;
;; Type mapping
;;   object  <-> hash table with string keys
;;   array   <-> list
;;   string  <-> string
;;   number  <-> number
;;   true    <-> t
;;   false    -> nil
;;   null    -> nil        ; and (json-stringify nil) -> "null"
;;
;; TWO CONFLATIONS, both forced by the language and both deliberate:
;;
;;   1. `false` and `null` BOTH decode to nil, because nil is the only false
;;      value KEC Lisp has. A caller that must tell an absent key from a null
;;      one asks the hash table, not the value: (hash-has? obj "key").
;;   2. nil is also the empty list, so it encodes as "null", never "[]". A list
;;      of elements round-trips; an empty array does not.
;;
;; NUMBERS ARE SINGLE-PRECISION. fe_Number is a C `float` (kernel/fe.h), so
;; integers are exact only to +/-2^24 (16777216). A larger JSON integer (a
;; 64-bit id, an epoch-millisecond timestamp) decodes to the nearest float and
;; is silently wrong. Two rules follow: never do arithmetic on epoch seconds
;; from an API, and keep ISO 8601 timestamps as strings and compare them
;; lexically (which is exactly what ISO 8601 is ordered for).
;;
;; A JSON string is NEVER coerced to a number. Only a JSON number token becomes
;; one. An API identifier like "6a75cffcf2928a45b1993f68" stays the string it
;; is; running it through string->number would silently yield 6.
;;
;; BOTH DIRECTIONS ARE ITERATIVE, over an explicit vector stack. The device
;; build's GC root stack is 256 slots, so recursive descent over nested JSON
;; would exhaust it on input a server can trivially produce. Nesting depth here
;; costs heap rather than GC roots, matching the style of core/10-list.lsp.
;;
;; Loads after 65-strtool (it uses pad-left / char-digit? / char-whitespace?)
;; and before 70-sort.

;; --- an explicit growable stack over a vector ---------------------------
;;
;; (vector . live-count), doubling when full. The parser stacks one frame per
;; open container; the writer stacks one task per pending emission.

(defn %json-stack ()
  (cons (make-vector 32 nil) 0))

(defn %json-depth (st)
  (cdr st))

(defn %json-push! (st x)
  (let v (car st))
  (let n (cdr st))
  (if (is n (vector-length v))
      (do
        (let bigger (make-vector (* n 2) nil))
        (let i 0)
        (while (< i n)
          (vector-set! bigger i (vector-ref v i))
          (set i (+ i 1)))
        (setcar st bigger)
        (set v bigger)))
  (vector-set! v n x)
  (setcdr st (+ n 1))
  x)

(defn %json-pop! (st)
  (let n (- (cdr st) 1))
  (if (< n 0) (raise "json: stack underflow") nil)
  (setcdr st n)
  (vector-ref (car st) n))

(defn %json-top (st)
  (vector-ref (car st) (- (cdr st) 1)))

;; Both directions assemble their output from a list of pieces and collapse it
;; with `string-concat` (core/65-strtool.lsp), which is neither quadratic nor
;; GC-root hungry. See the note there.

;; --- reader -------------------------------------------------------------

(defn %json-err (what i)
  (raise (str "json-parse: " what " at byte " i)))

;; (%json-skip s n i) — index of the next non-whitespace byte at or after i.
(defn %json-skip (s n i)
  (while (and (< i n) (char-whitespace? (string-ref s i)))
    (set i (+ i 1)))
  i)

(defn %json-hex-digit (c i)
  (cond
    ((and (<= 48 c) (<= c 57))  (- c 48))    ; 0-9
    ((and (<= 97 c) (<= c 102)) (- c 87))    ; a-f
    ((and (<= 65 c) (<= c 70))  (- c 55))    ; A-F
    (else (%json-err "invalid hex digit in \\u escape" i))))

;; (%json-hex4 s n i) — the 4 hex digits starting at i, as a code point.
(defn %json-hex4 (s n i)
  (if (< n (+ i 4)) (%json-err "truncated \\u escape" i) nil)
  (let v 0)
  (let k 0)
  (while (< k 4)
    (set v (+ (* v 16) (%json-hex-digit (string-ref s (+ i k)) (+ i k))))
    (set k (+ k 1)))
  v)

;; (%json-utf8 cp i) — a code point as UTF-8 bytes.
;; U+0000 raises: KEC strings are NUL-terminated, so a literal NUL would
;; truncate the string instead of appearing in it. Losing it silently would be
;; worse than refusing it.
(defn %json-utf8 (cp i)
  (cond
    ((is cp 0) (%json-err "\\u0000 cannot appear in a KEC string" i))
    ((< cp 128) (char->string cp))
    ((< cp 2048)
     (str (char->string (+ 192 (bit-shr cp 6)))
          (char->string (+ 128 (bit-and cp 63)))))
    ((< cp 65536)
     (str (char->string (+ 224 (bit-shr cp 12)))
          (char->string (+ 128 (bit-and (bit-shr cp 6) 63)))
          (char->string (+ 128 (bit-and cp 63)))))
    (else
     (str (char->string (+ 240 (bit-shr cp 18)))
          (char->string (+ 128 (bit-and (bit-shr cp 12) 63)))
          (char->string (+ 128 (bit-and (bit-shr cp 6) 63)))
          (char->string (+ 128 (bit-and cp 63)))))))

;; (%json-scan-string s n i) — i is the opening quote. Returns (value . next-i).
;; Unescaped runs are taken whole with substring, so a string with no escapes
;; costs one copy rather than one per character.
(defn %json-scan-string (s n i)
  (let chunks nil)
  (let start (+ i 1))
  (let j start)
  (let out nil)
  (while (nil? out)
    (if (<= n j) (%json-err "unterminated string" i) nil)
    (let c (string-ref s j))
    (cond
      ((is c 34)                                          ; closing quote
       (set chunks (cons (substring s start j) chunks))
       (set out (cons (string-concat (reverse chunks)) (+ j 1))))
      ((is c 92)                                          ; backslash
       (set chunks (cons (substring s start j) chunks))
       (let e (string-ref s (+ j 1)))
       (if (nil? e) (%json-err "truncated escape" j) nil)
       (cond
         ((is e 34)  (set chunks (cons "\"" chunks))            (set j (+ j 2)))
         ((is e 92)  (set chunks (cons "\\" chunks))            (set j (+ j 2)))
         ((is e 47)  (set chunks (cons "/" chunks))             (set j (+ j 2)))
         ((is e 98)  (set chunks (cons (char->string 8) chunks))  (set j (+ j 2)))
         ((is e 102) (set chunks (cons (char->string 12) chunks)) (set j (+ j 2)))
         ((is e 110) (set chunks (cons (char->string 10) chunks)) (set j (+ j 2)))
         ((is e 114) (set chunks (cons (char->string 13) chunks)) (set j (+ j 2)))
         ((is e 116) (set chunks (cons (char->string 9) chunks))  (set j (+ j 2)))
         ((is e 117)
          (let cp (%json-hex4 s n (+ j 2)))
          (set j (+ j 6))
          ;; A code point above U+FFFF arrives as a surrogate pair; a lone
          ;; surrogate is malformed either way round.
          (if (and (<= 55296 cp) (<= cp 56319))
              (do
                (if (or (< n (+ j 2))
                        (not (is (string-ref s j) 92))
                        (not (is (string-ref s (+ j 1)) 117)))
                    (%json-err "unpaired high surrogate" j) nil)
                (let lo (%json-hex4 s n (+ j 2)))
                (if (not (and (<= 56320 lo) (<= lo 57343)))
                    (%json-err "invalid low surrogate" j) nil)
                (set j (+ j 6))
                (set cp (+ 65536 (+ (* 1024 (- cp 55296)) (- lo 56320)))))
              (if (and (<= 56320 cp) (<= cp 57343))
                  (%json-err "unpaired low surrogate" j)
                  nil))
          (set chunks (cons (%json-utf8 cp j) chunks)))
         (else (%json-err "invalid escape" (+ j 1))))
       (set start j))
      ((< c 32) (%json-err "unescaped control character in string" j))
      (else (set j (+ j 1)))))
  out)

;; (%json-scan-number s n i) — returns (value . next-i). The token is validated
;; against the JSON grammar first (no leading zeros, no bare ".5" or "1."), and
;; only then handed to string->number, so nothing else can reach that call.
(defn %json-scan-number (s n i)
  (let j i)
  (if (is (string-ref s j) 45) (set j (+ j 1)) nil)      ; leading '-'
  (let ds j)
  (while (and (< j n) (char-digit? (string-ref s j)))
    (set j (+ j 1)))
  (if (is j ds) (%json-err "expected a digit" j) nil)
  (if (and (is (string-ref s ds) 48) (< 1 (- j ds)))
      (%json-err "number has a leading zero" ds) nil)
  (if (and (< j n) (is (string-ref s j) 46))             ; fraction
      (do
        (set j (+ j 1))
        (let fs j)
        (while (and (< j n) (char-digit? (string-ref s j)))
          (set j (+ j 1)))
        (if (is j fs) (%json-err "expected a digit after '.'" j) nil))
      nil)
  (if (and (< j n) (or (is (string-ref s j) 101) (is (string-ref s j) 69)))  ; e/E
      (do
        (set j (+ j 1))
        (if (and (< j n) (or (is (string-ref s j) 43) (is (string-ref s j) 45)))
            (set j (+ j 1)) nil)
        (let es j)
        (while (and (< j n) (char-digit? (string-ref s j)))
          (set j (+ j 1)))
        (if (is j es) (%json-err "expected a digit in the exponent" j) nil))
      nil)
  (cons (string->number (substring s i j)) j))

;; (%json-lit s i word) — the literal `word` must sit at i, or raise.
(defn %json-lit (s i word)
  (let len (string-length word))
  (if (is (substring s i (+ i len)) word)
      (+ i len)
      (%json-err (str "expected " word) i)))

;; A parse frame is a 3-slot vector: kind, accumulator, pending object key.
;; Arrays accumulate a reversed list; objects accumulate straight into a hash
;; table and park the key they have read but not yet used.
(defn %json-frame (kind acc)
  (vector kind acc ':none))

(defn %json-finish (f)
  (if (is (vector-ref f 0) ':array)
      (reverse (vector-ref f 1))
      (vector-ref f 1)))

;; (json-parse s) — decode one JSON document. Raises (catchable by `try`, with
;; the message readable via error-message) on anything malformed, always naming
;; the byte offset: a silent partial parse is worse than a failure.
(defn json-parse (s)
  (if (not (string? s)) (raise "json-parse: expected a string") nil)
  (let n (string-length s))
  (let st (%json-stack))
  (let i (%json-skip s n 0))
  (let val nil)       ; the most recently completed value
  (let have nil)      ; ... and whether there is one waiting to be attached
  (let result nil)
  (let done nil)
  (while (not done)
    (if have
        ;; --- attach the finished value, then take a separator or a closer ---
        (if (is (%json-depth st) 0)
            (do (set result val) (set have nil) (set done 1))
            (do
              (let f (%json-top st))
              (if (is (vector-ref f 0) ':array)
                  (vector-set! f 1 (cons val (vector-ref f 1)))
                  (do
                    (hash-set! (vector-ref f 1) (vector-ref f 2) val)
                    (vector-set! f 2 ':none)))
              (set have nil)
              (set i (%json-skip s n i))
              (let c (string-ref s i))
              (let closer (if (is (vector-ref f 0) ':array) 93 125))
              (cond
                ((nil? c) (%json-err "unexpected end of input" i))
                ((is c closer)
                 (set i (+ i 1))
                 (set val (%json-finish (%json-pop! st)))
                 (set have 1))
                ((is c 44)                                  ; ','
                 (set i (%json-skip s n (+ i 1))))
                (else (%json-err "expected ',' or a closing bracket" i)))))
        ;; --- scan the next value (reading an object key first, if one is due)
        (do
          (if (and (< 0 (%json-depth st))
                   (is (vector-ref (%json-top st) 0) ':object)
                   (is (vector-ref (%json-top st) 2) ':none))
              (do
                (let f (%json-top st))
                (if (not (is (string-ref s i) 34))
                    (%json-err "expected a string key" i) nil)
                (let kr (%json-scan-string s n i))
                (vector-set! f 2 (car kr))
                (set i (%json-skip s n (cdr kr)))
                (if (not (is (string-ref s i) 58))
                    (%json-err "expected ':' after an object key" i) nil)
                (set i (%json-skip s n (+ i 1))))
              nil)
          (let c (string-ref s i))
          (cond
            ((nil? c) (%json-err "unexpected end of input" i))
            ((is c 91)                                      ; '['
             (set i (%json-skip s n (+ i 1)))
             (if (is (string-ref s i) 93)
                 (do (set i (+ i 1)) (set val nil) (set have 1))
                 (%json-push! st (%json-frame ':array nil))))
            ((is c 123)                                     ; '{'
             (set i (%json-skip s n (+ i 1)))
             (if (is (string-ref s i) 125)
                 (do (set i (+ i 1)) (set val (make-hash-table)) (set have 1))
                 (%json-push! st (%json-frame ':object (make-hash-table)))))
            ((is c 34)                                      ; '"'
             (let r (%json-scan-string s n i))
             (set val (car r)) (set i (cdr r)) (set have 1))
            ((or (is c 45) (char-digit? c))                  ; '-' or a digit
             (let r (%json-scan-number s n i))
             (set val (car r)) (set i (cdr r)) (set have 1))
            ((is c 116)                                     ; 't'
             (set i (%json-lit s i "true")) (set val t) (set have 1))
            ((is c 102)                                     ; 'f'
             (set i (%json-lit s i "false")) (set val nil) (set have 1))
            ((is c 110)                                     ; 'n'
             (set i (%json-lit s i "null")) (set val nil) (set have 1))
            (else (%json-err "unexpected character" i))))))
  (set i (%json-skip s n i))
  (if (< i n) (%json-err "trailing content after the JSON value" i) nil)
  result)

;; --- writer -------------------------------------------------------------

;; (%json-number v) — %.7g already emits JSON-shaped numbers (including
;; "1e+10"). Infinities and NaN have no JSON spelling; both render with letters
;; no finite number's rendering contains, so one search catches them.
(defn %json-number (v)
  (let out (number->string v))
  (if (string-search out "n")
      (raise (str "json-stringify: " out " is not a JSON number"))
      nil)
  out)

;; (%json-quote s) — s as a quoted JSON string. Bytes >= 0x20 pass through
;; verbatim, so UTF-8 input stays UTF-8 output; control bytes take their short
;; escape or \u00XX.
(defn %json-quote (s)
  (let n (string-length s))
  (let chunks nil)
  (let start 0)
  (let i 0)
  (while (< i n)
    (let c (string-ref s i))
    (let esc (cond
               ((is c 34) "\\\"")
               ((is c 92) "\\\\")
               ((is c 8)  "\\b")
               ((is c 12) "\\f")
               ((is c 10) "\\n")
               ((is c 13) "\\r")
               ((is c 9)  "\\t")
               ((< c 32)  (str "\\u00" (pad-left (number->string c 16) 2 "0")))
               (else nil)))
    (if esc
        (do
          (set chunks (cons (substring s start i) chunks))
          (set chunks (cons esc chunks))
          (set start (+ i 1)))
        nil)
    (set i (+ i 1)))
  (set chunks (cons (substring s start n) chunks))
  (str "\"" (string-concat (reverse chunks)) "\""))

;; A writer task is either (:emit . string), appended verbatim, or
;; (:val . value), encoded and possibly pushing more tasks. Building the task list by consing
;; yields exactly the reverse of the emission order, which is the push order a
;; LIFO stack needs.
(defn %json-tasks-array (xs)
  (let e nil)
  (let first 1)
  (while xs
    (if first (set first nil) (set e (cons (cons ':emit ",") e)))
    (set e (cons (cons ':val (car xs)) e))
    (set xs (cdr xs)))
  (cons (cons ':emit "]") e))

(defn %json-tasks-object (h)
  (let e nil)
  (let first 1)
  (let ks (hash-keys h))
  (while ks
    (let k (car ks))
    (if (not (string? k))
        (raise (str "json-stringify: object key is not a string: " (repr k)))
        nil)
    (if first (set first nil) (set e (cons (cons ':emit ",") e)))
    (set e (cons (cons ':emit (%json-quote k)) e))
    (set e (cons (cons ':emit ":") e))
    (set e (cons (cons ':val (hash-ref h k)) e))
    (set ks (cdr ks)))
  (cons (cons ':emit "}") e))

;; (json-stringify x) — encode x as JSON. Raises on a value with no JSON
;; spelling (a symbol, a function, a vector, an infinity). Object key order
;; follows hash-keys, which is unspecified, so compare decoded values rather
;; than rendered text.
(defn json-stringify (x)
  (let st (%json-stack))
  (%json-push! st (cons ':val x))
  (let out nil)
  (while (< 0 (%json-depth st))
    (let task (%json-pop! st))
    (if (is (car task) ':emit)
        (set out (cons (cdr task) out))
        (do
          (let v (cdr task))
          (cond
            ((nil? v)          (set out (cons "null" out)))
            ((is v t)          (set out (cons "true" out)))
            ((number? v)       (set out (cons (%json-number v) out)))
            ((string? v)       (set out (cons (%json-quote v) out)))
            ((hash-table? v)
             (set out (cons "{" out))
             (let tasks (%json-tasks-object v))
             (while tasks (%json-push! st (car tasks)) (set tasks (cdr tasks))))
            ((pair? v)
             (set out (cons "[" out))
             (let tasks (%json-tasks-array v))
             (while tasks (%json-push! st (car tasks)) (set tasks (cdr tasks))))
            (else (raise (str "json-stringify: cannot encode " (repr v))))))))
  (string-concat (reverse out)))
