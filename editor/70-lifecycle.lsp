;; KEC Lisp editor tier — lifecycle : the session state machine + hooks (L8).
;;
;; Part of the editor/REPL tier (ADR-0002). Owns the lifecycle STATE and fires
;; HOOKS the host subscribes to (SEAM S6); it performs NO device side effects
;; itself — entering the editor, pausing CIPHER, preserving a framebuffer, etc.
;; are the host's, run from its hook callbacks.
;;
;; States: :init -> :editor | :repl -> ... -> :exited | :shutdown. `set-mode`
;; moves among the five keymap scopes. Hooks fire on enter / exit / mode-change.
;;
;; record = vector [state mode hooks] ; hooks = alist of (event . fn)

(defn make-lifecycle () (vector ':init nil nil))

(defn lifecycle-state (lc) (vector-ref lc 0))
(defn lifecycle-mode (lc) (vector-ref lc 1))
(defn %lc-hooks (lc) (vector-ref lc 2))

;; (lifecycle-add-hook lc event fn) — subscribe to :enter / :exit / :mode-change.
;; :enter and :exit hooks are called as (fn lc); :mode-change as (fn lc mode).
;; Returns lc.
(defn lifecycle-add-hook (lc event fn)
  (vector-set! lc 2 (cons (cons event fn) (%lc-hooks lc)))
  lc)

(defn %lc-fire1 (lc event)
  (for-each (fn (h) (when (is (car h) event) ((cdr h) lc))) (%lc-hooks lc)))

(defn %lc-fire2 (lc event arg)
  (for-each (fn (h) (when (is (car h) event) ((cdr h) lc arg))) (%lc-hooks lc)))

;; ----- transitions ------------------------------------------------------
(defn lifecycle-enter-editor! (lc)
  (vector-set! lc 0 ':editor) (%lc-fire1 lc ':enter) lc)

(defn lifecycle-enter-repl! (lc)
  (vector-set! lc 0 ':repl) (%lc-fire1 lc ':enter) lc)

(defn lifecycle-exit! (lc)
  (vector-set! lc 0 ':exited) (%lc-fire1 lc ':exit) lc)

(defn lifecycle-shutdown! (lc)
  (vector-set! lc 0 ':shutdown) (%lc-fire1 lc ':exit) lc)

;; (lifecycle-set-mode! lc mode) — set the active keymap scope; fire :mode-change.
(defn lifecycle-set-mode! (lc mode)
  (vector-set! lc 1 mode) (%lc-fire2 lc ':mode-change mode) lc)

(provide 'editor/lifecycle)
