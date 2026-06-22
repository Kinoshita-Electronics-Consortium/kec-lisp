;; KEC Core — recover : error-recovery macros over try/raise
;;
;; The kernel + runtime already give error *catching*: (try thunk) returns the
;; thunk's value or an error value (:error . msg), with error?/error-message in
;; 35-error. These macros build the higher-level recovery forms knEmacs's command
;; loop and save-excursion-class wrappers need. This module loads BEFORE
;; quasiquote (45), so expansions are built by hand with list/cons (the 40-ctrl
;; style); gensym (a host primitive) keeps the captured result temporary from
;; colliding with user names.

;; (unwind-protect body . cleanup) — run body, then ALWAYS run the cleanup
;; forms (both on normal return and on a raised error). On error the cleanup
;; runs first, then the error is re-raised (message-only — KEC errors carry just
;; a message) so the surrounding handler still sees the failure.
(set unwind-protect (mac (body . cleanup)
  (let r (gensym))
  (list 'do
    (list 'let r (list 'try (list 'fn nil body)))
    (cons 'do cleanup)
    (list 'if (list 'error? r)
          (list 'raise (list 'error-message r))
          r))))

;; (ignore-errors body...) — evaluate body, yielding nil on any raised error.
(set ignore-errors (mac body
  (let r (gensym))
  (list 'do
    (list 'let r (list 'try (cons 'fn (cons nil body))))
    (list 'if (list 'error? r) nil r))))

;; (condition-case var bodyform handler...) — catch a raised error. Message-based
;; (class dispatch is deferred): the first handler is the catch-all; `var` is
;; bound to the (:error . msg) value inside the handler body. With no handlers,
;; the result (value or error) is returned as-is.
;; The handler clause expands to (do (let var r) handler-body...) so the `var`
;; binding and the handler body are SIBLINGS in one `do` — that is how a kernel
;; `let` threads its binding forward (a third arg to `let` itself is ignored).
(set condition-case (mac (var bodyform . handlers)
  (let r (gensym))
  (list 'do
    (list 'let r (list 'try (list 'fn nil bodyform)))
    (list 'if (list 'error? r)
          (if handlers
              (cons 'do (cons (list 'let var r) (cdr (car handlers))))
              r)
          r))))

;; (macroexpand form) — full expansion: loop macroexpand-1 to a fixpoint.
;; macroexpand-1 returns the SAME object when nothing expands, so an identity
;; test (is) terminates the loop.
(defn macroexpand (form)
  (let next (macroexpand-1 form))
  (while (not (is next form))
    (set form next)
    (set next (macroexpand-1 form)))
  form)
