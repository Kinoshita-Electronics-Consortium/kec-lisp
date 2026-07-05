;; KEC Core — recover : error-recovery macros over try/raise
;;
;; The kernel + runtime already give error *catching*: (try thunk) returns the
;; thunk's value or an error value (:error . msg), with error?/error-message in
;; 35-error. These macros build the higher-level recovery forms knEmacs's command
;; loop and save-excursion-class wrappers need. This module loads BEFORE
;; quasiquote (45), so expansions are built by hand with list/cons (the 40-ctrl
;; style); gensym (a host primitive) keeps the captured result temporary from
;; colliding with user names.

;; %recover-tag — a unique load-time pair marking the NORMAL-return path
;; inside these macros' try thunks. `try` alone cannot distinguish a raised
;; error from a body that legitimately *returns* an (:error . msg) value —
;; (error ...) in 35-error builds exactly the shape try returns on a raise.
;; Wrapping the normal result as (%recover-tag . value) makes the raise path
;; unambiguous: `is` compares pairs by identity, and no body can produce this
;; exact pair without referencing it. %-private; do not shadow (same contract
;; as %append — see core/10-list.lsp).
(set %recover-tag (cons ':recover-ok nil))

;; (unwind-protect body . cleanup) — run body, then ALWAYS run the cleanup
;; forms (both on normal return and on a raised error). On a raise the cleanup
;; runs first, then the error is re-raised (message-only — KEC errors carry just
;; a message) so the surrounding handler still sees the failure. A body that
;; RETURNS an (:error . msg) value is a normal return: cleanup runs, the value
;; passes through, nothing is re-raised.
(set unwind-protect (mac (body . cleanup)
  (let r (gensym))
  (list 'do
    (list 'let r (list 'try (list 'fn nil (list 'cons '%recover-tag body))))
    (cons 'do cleanup)
    (list 'if (list 'is (list 'car r) '%recover-tag)
          (list 'cdr r)
          (list 'raise (list 'error-message r))))))

;; (ignore-errors body...) — evaluate body, yielding nil on any raised error.
;; A returned (:error . msg) value is a value, not a raise: it passes through.
(set ignore-errors (mac body
  (let r (gensym))
  (list 'do
    (list 'let r (list 'try (list 'fn nil
                                  (list 'cons '%recover-tag (cons 'do body)))))
    (list 'if (list 'is (list 'car r) '%recover-tag)
          (list 'cdr r)
          nil))))

;; (condition-case var bodyform handler...) — catch a raised error. Message-based
;; (class dispatch is deferred): the first handler is the catch-all; `var` is
;; bound to the (:error . msg) value inside the handler body. With no handlers,
;; the result (value or error) is returned as-is. The handler runs only on a
;; RAISED error — a bodyform that returns an (:error . msg) value is a normal
;; return.
;; The handler clause expands to (do (let var r) handler-body...) so the `var`
;; binding and the handler body are SIBLINGS in one `do` — that is how a kernel
;; `let` threads its binding forward (a third arg to `let` itself is ignored).
(set condition-case (mac (var bodyform . handlers)
  (let r (gensym))
  (list 'do
    (list 'let r (list 'try (list 'fn nil (list 'cons '%recover-tag bodyform))))
    (list 'if (list 'is (list 'car r) '%recover-tag)
          (list 'cdr r)
          (if handlers
              (cons 'do (cons (list 'let var r) (cdr (car handlers))))
              r)))))

;; (macroexpand form) — full expansion: loop macroexpand-1 to a fixpoint.
;; macroexpand-1 returns the SAME object when nothing expands, so an identity
;; test (is) terminates the loop.
(defn macroexpand (form)
  (let next (macroexpand-1 form))
  (while (not (is next form))
    (set form next)
    (set next (macroexpand-1 form)))
  form)
