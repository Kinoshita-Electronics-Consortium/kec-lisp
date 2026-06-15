;; KEC Lisp — require/provide conformance.
;;
;; require is FULL-profile only because it loads files. provide/provided? are
;; available as runtime feature markers.

(deftest "provide/provided?"
  (check (nil? (provided? 'kec-test-feature)))
  (check (is (provide 'kec-test-feature) 'kec-test-feature))
  (check (provided? 'kec-test-feature)))

(deftest "require/load-once-by-path"
  (let path "kec-require-once.tmp.lsp")
  (write-file path "(set %require-count (+ %require-count 1))")
  (set %require-count 0)
  (require path)
  (require path)
  (check (is %require-count 1)))

(deftest "require/feature-with-path"
  (let path "kec-require-feature.tmp.lsp")
  (write-file path "(set %require-feature-value 42) (provide 'kec-require-feature)")
  (set %require-feature-value 0)
  (require 'kec-require-feature path)
  (require 'kec-require-feature path)
  (check (is %require-feature-value 42))
  (check (provided? 'kec-require-feature)))
