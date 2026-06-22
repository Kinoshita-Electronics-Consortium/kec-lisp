;; KEC Lisp editor tier — prompt : the structural REPL prompt (:repl-prompt).
;;
;; Part of the editor/REPL tier (ADR-0002, L1.5/L6.1). The REPL prompt is itself a
;; structural buffer: you compose the input form with the editor verbs and EVAL
;; submits it to the REPL engine, then the prompt resets. A prompt-session bundles
;; a prompt buffer + a repl; the default :repl-prompt keymap edits the buffer
;; structurally and binds EVAL to submit.
;;
;; Load order: after 30-buffer, 50-keymap, 60-persist, 90-repl.

;; prompt-session = vector [prompt-buffer repl]
(defn make-prompt-session (repl)
  (vector (make-buffer "*prompt*" (read-all "()")) repl))

(defn prompt-buffer (ps) (vector-ref ps 0))
(defn prompt-repl (ps) (vector-ref ps 1))

;; (prompt-submit! ps) — submit the prompt's current top-level form to the REPL,
;; then reset the prompt buffer. Returns the new history entry.
(defn prompt-submit! (ps)
  (let entry (car (repl-submit (prompt-repl ps)
                               (buffer-current-form (prompt-buffer ps)))))
  (buffer-reload! (prompt-buffer ps) "()")     ; clear the prompt
  entry)

;; default :repl-prompt keymap — structural editing of the prompt buffer plus
;; EVAL to submit. Handlers take and return the prompt-session.
(define *repl-prompt-keymap* (make-keymap))
(define-key *repl-prompt-keymap* 'CAR   (fn (ps) (do (buffer-descend! (prompt-buffer ps)) ps)))
(define-key *repl-prompt-keymap* 'CDR   (fn (ps) (do (buffer-next!    (prompt-buffer ps)) ps)))
(define-key *repl-prompt-keymap* 'QUOTE (fn (ps) (do (buffer-prev!    (prompt-buffer ps)) ps)))
(define-key *repl-prompt-keymap* 'BACK  (fn (ps) (do (buffer-ascend!  (prompt-buffer ps)) ps)))
(define-key *repl-prompt-keymap* 'CONS  (fn (ps) (do (buffer-wrap!    (prompt-buffer ps)) ps)))
(define-key *repl-prompt-keymap* 'EVAL  (fn (ps) (do (prompt-submit! ps) ps)))
(register-keymap MODE-REPL-PROMPT *repl-prompt-keymap*)

(provide 'editor/prompt)
