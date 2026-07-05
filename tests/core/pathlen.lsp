;; Over-long path / name / conversion arguments raise a catchable error
;; instead of being silently truncated at the 4 KB scratch-buffer ceiling —
;; a clipped path names a DIFFERENT file (write-file would clobber the wrong
;; target), and truncate-then-parse misreads string->number input. Feature
;; keys are bounded at 1 KB the same way, so two long names sharing a prefix
;; can't dedupe into one. (Repository review sweep, final pass.)

(let %too-long (string-repeat "x" 5000))
(let %long-key (string-repeat "k" 1500))

(deftest "pathlen/file primitives raise on over-long paths"
  (check-err (read-file %too-long))
  (check-err (write-file %too-long "x"))
  (check-err (append-file %too-long "x"))
  (check-err (file-exists? %too-long))
  (check-err (list-dir %too-long))
  (check-err (getenv %too-long))
  (check-err (load %too-long))
  (check-err (require '%pathlen-nope %too-long)))

(deftest "pathlen/conversions raise instead of truncate-then-act"
  (check-err (string->number (string-append "1" %too-long)))
  (check-err (string->symbol %too-long))
  (check-err (symbol->string %too-long)))

(deftest "pathlen/feature names are bounded"
  (check-err (provide %long-key))
  (check-err (provided? %long-key))
  (check-err (require %long-key)))

(deftest "pathlen/in-range arguments still work"
  (check (nil? (file-exists? (string-repeat "x" 100))))
  (check (is (string->number "42") 42))
  (check (is (symbol->string 'abc) "abc")))
