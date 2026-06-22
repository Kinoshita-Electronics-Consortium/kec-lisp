;; KEC Lisp editor tier — reference-host conformance (the SEAM device-free proof).
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/50-keymap.lsp")
(load "editor/80-ranker.lsp")
(load "editor/90-repl.lsp")
(load "editor/95-host.lsp")

(deftest "host/repl-line-evals-and-formats"
  (let s (make-session 16 40))
  (check (= (host-repl-line s "(+ 2 3)") "5"))
  (check (= (host-repl-line s "(list 1 2 3)") "(1 2 3)")))

(deftest "host/blank-line-drops"
  (let s (make-session 16 40))
  (check (nil? (host-repl-line s "   ")))
  (check (is (repl-count (session-repl s)) 0)))

(deftest "host/error-survives-loop"
  (let s (make-session 16 40))
  (check (string-prefix? (host-repl-line s "(car 5)") "error:"))
  (check (= (host-repl-line s "(* 4 5)") "20")))     ; loop kept alive

(deftest "host/history-accumulates"
  (let s (make-session 16 40))
  (host-repl-line s "1")
  (host-repl-line s "2")
  (check (is (repl-count (session-repl s)) 2)))

(deftest "host/complete-from-live-globals"
  (let s (make-session 16 40))
  (let cands (host-complete s "string-"))
  (check (not (nil? cands)))                          ; string-* globals exist
  (check (every? (fn (c) (string-prefix? c "string-")) cands))
  (check (<= (length cands) 8)))                      ; top-8 bound

(deftest "host/complete-no-match"
  (let s (make-session 16 40))
  (check (nil? (host-complete s "zzz-no-such-prefix-"))))
