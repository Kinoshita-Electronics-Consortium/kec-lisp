;; KEC Lisp — large-string conformance (GWP-528).
;;
;; The host string primitives used to copy through a fixed 4 KB C buffer, so any
;; string past ~4095 bytes was silently truncated by string-length / string-ref /
;; substring / str — and therefore by Core split / join too. These checks build
;; strings well past that old ceiling and assert the operations see every byte.

;; Build an n-character string of `ch` by repeated doubling. Count-based (a
;; fixed number of doublings, then one substring) — never length-based, so it
;; can't loop forever if string-length itself is the thing under test and is
;; reporting a truncated value.
(defn make-big (ch n)
  (let s (char->string ch))
  (let cap 1)
  (while (< cap n) (set s (str s s)) (set cap (* cap 2)))
  (substring s 0 n))

(deftest "bigstr/string-length"
  (let big (make-big 65 8192))
  (check (is (string-length big) 8192)))      ; not 4095

(deftest "bigstr/string-ref"
  (let big (make-big 65 8192))
  (check (is (string-ref big 0) 65))          ; first byte
  (check (is (string-ref big 8191) 65))       ; last byte — past the old ceiling
  (check (nil? (string-ref big 8192))))       ; one past the end -> nil

(deftest "bigstr/substring"
  ;; A 10000-byte string: first half 'A' (65), second half 'B' (66). Slicing
  ;; across the old 4 KB boundary must return the right bytes.
  (let half (make-big 65 5000))
  (let big (str half (make-big 66 5000)))
  (check (is (string-length big) 10000))
  (check (is (string-ref (substring big 4999 5000) 0) 65))   ; last 'A'
  (check (is (string-ref (substring big 5000 5001) 0) 66))   ; first 'B'
  (check (is (string-length (substring big 4000 9000)) 5000)))

(deftest "bigstr/str-concat"
  ;; str (string-append) must not truncate a long concatenation.
  (let a (make-big 65 6000))
  (let b (make-big 66 6000))
  (let both (str a b))
  (check (is (string-length both) 12000))
  (check (is (string-ref both 5999) 65))      ; end of the 'A' run
  (check (is (string-ref both 6000) 66)))     ; start of the 'B' run

(deftest "bigstr/split-join"
  ;; Core split / join run on top of the host string ops, so they used to
  ;; truncate too. Build "AAA...,BBB...,CCC..." with each field 3000 bytes
  ;; (total > 9000, past the old ceiling) and round-trip it.
  (let f1 (make-big 65 3000))
  (let f2 (make-big 66 3000))
  (let f3 (make-big 67 3000))
  (let line (join (list f1 f2 f3) ","))
  (check (is (string-length line) 9002))       ; 3*3000 + 2 separators
  (let parts (split line ","))
  (check (is (length parts) 3))
  (check (is (string-length (nth parts 0)) 3000))
  (check (is (string-length (nth parts 2)) 3000))
  (check (is (string-ref (nth parts 1) 0) 66))  ; field 2 is all 'B'
  (check (is (join parts ",") line)))           ; full round-trip
