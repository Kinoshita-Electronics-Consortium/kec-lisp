;; csv-roundtrip — end-to-end proof for the standalone-scripting essentials
;; (GWP-527): generate a CSV larger than the old 4 KB string ceiling, write it
;; with spit, read it back with slurp, parse rows with split, sort the rows by a
;; numeric column with the new Core sort, add a derived column, and write the
;; result back out — then read THAT back and verify.
;;
;; Exercises together: GWP-528 (no 4 KB truncation), GWP-529 (spit), and
;; GWP-532 (sort). Run with:  kec run examples/csv-roundtrip.lsp

(let nl "\n")
(let in-path "csv-roundtrip-in.csv")
(let out-path "csv-roundtrip-out.csv")

;; --- 1. Build a CSV well past 4 KB: header + 600 rows of "id,score,label". ---
;; The score column is a pseudo-shuffled value so the sort has real work to do;
;; the label widens each row so the whole document clears the old 4 KB ceiling.
(let rows nil)            ; reversed accumulator of "id,score,label" data lines
(let seed 7)
(let n 600)
(dotimes (i n)
  (set seed (mod (+ (* seed 1103515245) 12345) 2147483648))
  (let score (mod seed 1000))
  (set rows (cons (str (+ i 1) "," score "," "item-" (+ i 1)) rows)))
(set rows (reverse rows))

(let header "id,score,label")
(let csv (str header nl (join rows nl) nl))
(princ "generated CSV bytes: ") (princ (string-length csv)) (newline)

;; --- 2. Write it out, then read it back. The size proves no 4 KB clip. ---
(spit in-path csv)
(let back (slurp in-path))
(princ "slurped back bytes:  ") (princ (string-length back)) (newline)
(if (is (string-length back) (string-length csv))
    (princ "round-trip byte count: OK")
    (princ "round-trip byte count: MISMATCH"))
(newline)

;; --- 3. Parse: split into lines, drop the header, split each line on ",". ---
(let lines (split back nl))
;; The trailing newline yields a final empty field; drop empties.
(let data nil)
(dolist (line (cdr lines))                 ; (cdr lines) skips the header
  (if (< 0 (string-length line))
      (set data (cons (split line ",") data))))
(set data (reverse data))
(princ "data rows parsed:    ") (princ (length data)) (newline)

;; --- 4. Sort rows by the score column (field 1), ascending, with Core sort. ---
(defn row-score (r) (string->number (nth r 1)))
(let sorted (sort data (fn (a b) (< (row-score a) (row-score b)))))

;; --- 5. Derived column: rank (1-based position after sorting). ---
(let ranked nil)
(let rank 1)
(dolist (r sorted)
  ;; carry id,score,label through and append the derived rank
  (set ranked (cons (str (nth r 0) "," (nth r 1) "," (nth r 2) "," rank) ranked))
  (set rank (+ rank 1)))
(set ranked (reverse ranked))

;; --- 6. Write the transformed CSV out. ---
(let out-csv (str "id,score,label,rank" nl (join ranked nl) nl))
(spit out-path out-csv)

;; --- 7. Read the result back and verify the transform. ---
(let result (slurp out-path))
(let result-lines (split result nl))
(let first-data (split (nth result-lines 1) ","))   ; first data row after header
(let last-idx (- (length ranked) 1))
(let last-data (split (nth ranked last-idx) ","))

(princ "wrote CSV bytes:     ") (princ (string-length out-csv)) (newline)
(princ "lowest score (rank 1): ") (princ (nth first-data 1)) (newline)
(princ "highest score (rank ") (princ (length ranked)) (princ "): ")
(princ (nth last-data 1)) (newline)

;; Verify the sort actually ordered the scores non-decreasing.
(let ok 1)
(let prev -1)
(dolist (r sorted)
  (if (< (row-score r) prev) (set ok nil))
  (set prev (row-score r)))
(princ "scores non-decreasing: ")
(princ (if ok "OK" "FAIL"))
(newline)

(princ "done — wrote ") (princ out-path) (newline)
