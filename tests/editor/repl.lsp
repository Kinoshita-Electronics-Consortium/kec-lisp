;; KEC Lisp editor tier — REPL engine conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/50-keymap.lsp")
(load "editor/90-repl.lsp")

(defn mkrepl () (make-repl 16 40 nil))         ; cap 16, width 40, eval-fn = eval
(defn out (pair) (entry-output (car pair)))    ; the entry's output string

(deftest "repl/read-eval-print"
  (let r (mkrepl))
  (let res (repl-submit r (read-string "(+ 1 2)")))
  (check (= (out res) "3"))
  (check (entry-ok? (car res)))
  (check (is (repl-count r) 1)))

(deftest "repl/empty-submission-drops"
  (let r (mkrepl))
  (let res (repl-submit r nil))
  (check (nil? (car res)))                      ; no entry
  (check (is (repl-count r) 0)))

(deftest "repl/error-is-recoverable"
  (let r (mkrepl))
  (let res (repl-submit r (read-string "(car 5)")))   ; car of a non-pair raises
  (check (not (entry-ok? (car res))))
  (check (string-prefix? (out res) "error:"))
  ;; the loop survives and the input is preserved in history for retry
  (check (is (repl-count r) 1))
  (check (equal? (entry-input (car (repl-history r))) (read-string "(car 5)")))
  ;; a subsequent good submission still works
  (repl-submit r (read-string "(* 2 3)"))
  (check (= (entry-output (car (repl-history r))) "6")))

(deftest "repl/coalesce-consecutive-duplicates"
  (let r (mkrepl))
  (repl-submit r (read-string "(+ 1 1)"))
  (repl-submit r (read-string "(+ 1 1)"))       ; same input -> coalesced
  (check (is (repl-count r) 1))
  (repl-submit r (read-string "(+ 2 2)"))       ; different -> new entry
  (check (is (repl-count r) 2)))

(deftest "repl/saturate-and-evict-oldest"
  (let r (make-repl 2 40 nil))                  ; capacity 2
  (repl-submit r (read-string "1"))
  (repl-submit r (read-string "2"))
  (repl-submit r (read-string "3"))             ; evicts the oldest (1)
  (check (is (repl-count r) 2))
  (check (equal? (entry-input (car (repl-history r))) 3))         ; newest
  (check (equal? (entry-input (nth (repl-history r) 1)) 2)))      ; 1 is gone

(deftest "repl/format-canonical-and-opaque"
  (let r (mkrepl))
  (check (= (out (repl-submit r (read-string "42"))) "42"))            ; canonical number
  (check (= (out (repl-submit r (read-string "\"hi\""))) "\"hi\""))    ; quoted string
  (check (= (out (repl-submit r (read-string "(fn (x) x)"))) "#<fn>")) ; opaque -> tag
  (check (= (out (repl-submit r (read-string "(vector 1 2)"))) "#<ptr>")))

(deftest "repl/format-wide-list-breaks-over-lines"
  (let r (make-repl 16 8 nil))                  ; narrow width = 8
  (let res (repl-submit r (read-string "'(alpha beta gamma)")))  ; evals to the list
  ;; the flat result exceeds 8, so it breaks one element per line
  (check (string-contains? (out res) "\n"))
  ;; no single line exceeds the width
  (let lines (split (out res) "\n"))
  (check (every? (fn (l) (<= (string-length l) 8)) lines)))

(deftest "repl/history-walking"
  (let r (mkrepl))
  (repl-submit r (read-string "1"))
  (repl-submit r (read-string "2"))
  (repl-submit r (read-string "3"))
  (check (nil? (repl-recall r)))                ; at the prompt
  (repl-older! r)                               ; -> newest (3)
  (check (equal? (entry-input (repl-recall r)) 3))
  (repl-older! r)                               ; -> 2
  (check (equal? (entry-input (repl-recall r)) 2))
  (repl-newer! r)                               ; -> 3
  (check (equal? (entry-input (repl-recall r)) 3))
  (repl-newer! r)                               ; -> back to prompt
  (check (nil? (repl-recall r))))

(deftest "repl/reeval-recalled"
  (let r (mkrepl))
  (repl-submit r (read-string "(+ 10 5)"))
  (repl-older! r)                               ; recall it
  (repl-reeval! r)                              ; re-execute
  (check (= (entry-output (car (repl-history r))) "15")))

(deftest "repl/history-keymap-walks"
  (let r (mkrepl))
  (repl-submit r (read-string "1"))
  (repl-submit r (read-string "2"))
  (mode-dispatch MODE-REPL-HISTORY 'CDR ':tap r)        ; older -> newest (2)
  (check (equal? (entry-input (repl-recall r)) 2))
  (mode-dispatch MODE-REPL-HISTORY 'CDR ':tap r)        ; older -> 1
  (check (equal? (entry-input (repl-recall r)) 1)))

(deftest "repl/guided-runner-does-not-consume-history"
  (let r (mkrepl))
  (let results (repl-run-guided r (list (cons (read-string "(+ 1 1)") 2)
                                        (cons (read-string "(+ 2 2)") 5))))  ; 2nd wrong
  (check (is (length results) 2))
  (check (nth (nth results 0) 1))               ; first passes (1+1=2)
  (check (not (nth (nth results 1) 1)))         ; second fails (2+2 != 5)
  (check (is (repl-count r) 0)))                ; history untouched
