;; KEC Lisp editor tier — host : a reference host session (SEAM wiring).
;;
;; The last tier module. It ties the engine into a runnable laptop REPL — the
;; strong standalone REPL and the device-free proof that the SEAM (S1-S9) carries
;; the whole engine with no new C seam. The `kec repl` subcommand drives this;
;; the KN-86 firmware provides its own host the same way (its surfaces, its
;; input, its persistence). Wiring:
;;   S1 eval context = `eval` (the FULL context's binding-set)
;;   S2 input        = the host hands lines / tokens to the driver below
;;   S4 render       = the formatted output string the driver returns
;;   S8 vocabulary   = the live globals (host-complete)
;; Requires the FULL/eval tier. Load order: after 90-repl.

;; session = vector [repl mode]
(defn make-session (capacity width)
  (vector (make-repl capacity width eval) ':repl-prompt))

(defn session-repl (s) (vector-ref s 0))
(defn session-mode (s) (vector-ref s 1))

;; (host-repl-line s line) -> the formatted output string, or nil for a blank
;; line. READ the line to a form (always a well-formed s-expression), submit it
;; to the REPL engine, and return the entry's output — the printed result, or an
;; "error: ..." message; either way the loop survives (L6.5).
(defn host-repl-line (s line)
  (let form (read-string line))
  (if (nil? form)
      nil
      (entry-output (car (repl-submit (session-repl s) form)))))

;; (host-complete s prefix) -> up to 8 ranked completion candidates from the
;; LIVE global environment whose names start with `prefix`. Dogfoods the ranker
;; against (globals) (SEAM S8 fed from the live image) — the laptop equivalent
;; of the device IntelliSense.
(defn host-complete (s prefix)
  (let names (map symbol->string (globals prefix)))
  (rank-tokens (map (fn (n) (cons n 'function)) names)
               (ranker-context 'function nil nil nil)
               (ranker-index names nil nil)))

(provide 'editor/host)
