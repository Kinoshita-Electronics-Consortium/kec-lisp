;; KEC Lisp — file output conformance (GWP-529).
;;
;; spit / spit-append are FULL-profile only (gated like slurp). These checks run
;; under `kec test`, which opens a FULL context. They write to a scratch file in
;; the current directory and read it back with slurp.

;; Same count-based big-string builder as bigstr.lsp (kept local so this file is
;; self-contained when run on its own).
(defn spit-make-big (ch n)
  (let s (char->string ch))
  (let cap 1)
  (while (< cap n) (set s (str s s)) (set cap (* cap 2)))
  (substring s 0 n))

(deftest "spit/roundtrip"
  (let path "kec-spit-test.tmp")
  (spit path "hello, deck")
  (check (is (slurp path) "hello, deck"))
  ;; spit overwrites, not appends.
  (spit path "second")
  (check (is (slurp path) "second")))

(deftest "spit/append"
  (let path "kec-spit-append.tmp")
  (spit path "AB")          ; create/overwrite
  (spit-append path "CD")   ; append
  (spit-append path "EF")
  (check (is (slurp path) "ABCDEF")))

(deftest "spit/append-creates"
  ;; spit-append on a non-existent file creates it.
  (let path "kec-spit-append-new.tmp")
  (spit path "")            ; ensure a known empty starting point
  (spit-append path "x")
  (check (is (slurp path) "x")))

(deftest "spit/large-write-byte-exact"
  ;; Writing past the old 4 KB ceiling must be byte-exact (depends on GWP-528).
  (let path "kec-spit-big.tmp")
  (let big (str (spit-make-big 65 5000) (spit-make-big 66 5000)))  ; 10000 bytes
  (spit path big)
  (let back (slurp path))
  (check (is (string-length back) 10000))
  (check (is (string-ref back 0) 65))
  (check (is (string-ref back 4999) 65))
  (check (is (string-ref back 5000) 66))
  (check (is (string-ref back 9999) 66)))

(deftest "spit/stringifies-nonstring"
  ;; spit accepts any value, stringified the writer's way (like str / princ).
  (let path "kec-spit-num.tmp")
  (spit path 42)
  (check (is (slurp path) "42")))
