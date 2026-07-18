;; KEC Lisp — file I/O conformance (GWP-529).
;;
;; read-file / write-file / append-file are FULL-profile only. These checks run
;; under `kec test`, which opens a FULL context. They write to scratch files in
;; the current directory and read them back with read-file.

;; Same count-based big-string builder as bigstr.lsp (kept local so this file is
;; self-contained when run on its own).
(defn fileio-make-big (ch n)
  (let s (char->string ch))
  (let cap 1)
  (while (< cap n) (set s (str s s)) (set cap (* cap 2)))
  (substring s 0 n))

(deftest "write-file/roundtrip"
  (let path "kec-write-file-test.tmp")
  (write-file path "hello, deck")
  (check (is (read-file path) "hello, deck"))
  ;; write-file overwrites, not appends.
  (write-file path "second")
  (check (is (read-file path) "second")))

(deftest "write-file/append"
  (let path "kec-append-file.tmp")
  (write-file path "AB")          ; create/overwrite
  (append-file path "CD")         ; append
  (append-file path "EF")
  (check (is (read-file path) "ABCDEF")))

(deftest "write-file/append-creates"
  ;; append-file on a non-existent file creates it.
  (let path "kec-append-file-new.tmp")
  (write-file path "")            ; ensure a known empty starting point
  (append-file path "x")
  (check (is (read-file path) "x")))

(deftest "write-file/large-write-byte-exact"
  ;; Writing past the old 4 KB ceiling must be byte-exact (depends on GWP-528).
  (let path "kec-write-file-big.tmp")
  (let big (str (fileio-make-big 65 5000) (fileio-make-big 66 5000)))  ; 10000 bytes
  (write-file path big)
  (let back (read-file path))
  (check (is (string-length back) 10000))
  (check (is (string-ref back 0) 65))
  (check (is (string-ref back 4999) 65))
  (check (is (string-ref back 5000) 66))
  (check (is (string-ref back 9999) 66)))

(deftest "write-file/stringifies-nonstring"
  ;; write-file accepts any value, stringified the writer's way (like str / princ).
  (let path "kec-write-file-num.tmp")
  (write-file path 42)
  (check (is (read-file path) "42")))

(deftest "file/read-write-append"
  ;; Descriptive names mirror read-string: read-file returns text, write-file
  ;; overwrites, and append-file appends.
  (let path "kec-file-roundtrip.tmp")
  (write-file path "A")
  (append-file path "B")
  (append-file path "C")
  (check (is (read-file path) "ABC"))
  (write-file path "Z")
  (check (is (read-file path) "Z")))

(deftest "write-file/blob-binary-safe"
  ;; A blob is written verbatim: NUL and high (>127) bytes must survive, which
  ;; the string path cannot do. read-blob reads them back byte-exact.
  (let path "kec-write-file-blob.tmp")
  (let b (make-blob 4))
  (blob-set! b 0 71)               ; 'G'
  (blob-set! b 1 0)                ; NUL — truncates a string, not a blob
  (blob-set! b 2 255)              ; high byte
  (blob-set! b 3 70)               ; 'F'
  (write-file path b)
  (let back (read-blob path))
  (check (is (blob-length back) 4))
  (check (is (blob-ref back 0) 71))
  (check (is (blob-ref back 1) 0))
  (check (is (blob-ref back 2) 255))
  (check (is (blob-ref back 3) 70)))

(deftest "write-file/blob-append"
  ;; append-file also takes the blob path; bytes concatenate byte-exact.
  (let path "kec-append-file-blob.tmp")
  (let a (make-blob 2 1))          ; 0x01 0x01
  (let b (make-blob 2 2))          ; 0x02 0x02
  (write-file path a)
  (append-file path b)
  (let back (read-blob path))
  (check (is (blob-length back) 4))
  (check (is (blob-ref back 0) 1))
  (check (is (blob-ref back 3) 2)))

(deftest "write-file/blob-empty"
  ;; A zero-length blob writes an empty file and round-trips to an empty blob.
  (let path "kec-write-file-blob-empty.tmp")
  (let e (make-blob 0))
  (write-file path e)
  (let back (read-blob path))
  (check (is (blob-length back) 0)))

(deftest "write-file/non-blob-unchanged"
  ;; The string/number stringify path is untouched by the blob branch.
  (let path "kec-write-file-nonblob.tmp")
  (write-file path "plain")
  (check (is (read-file path) "plain"))
  (write-file path 42)
  (check (is (read-file path) "42")))

(deftest "read-blob/errors"
  (let r (try (fn nil (read-blob "kec-no-such-file-xyzzy.tmp"))))
  (check (error? r))
  (check (is (error-message r) "read-blob: cannot open file")))

(deftest "file/preferred-name-errors"
  (let r (try (fn nil (read-file "kec-no-such-file-xyzzy.tmp"))))
  (check (error? r))
  (check (is (error-message r) "read-file: cannot open file"))
  (let w (try (fn nil (write-file "kec-no-such-dir-xyzzy/out.tmp" "x"))))
  (check (error? w))
  (check (is (error-message w) "write-file: cannot open file for writing")))
