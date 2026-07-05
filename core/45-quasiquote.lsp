;; KEC Core — quasiquote : macro construction without list/cons noise
;;
;; The reader maps:
;;   `x   -> (quasiquote x)
;;   ,x   -> (unquote x)
;;   ,@x  -> (unquote-splicing x)
;;
;; This macro expands quasiquoted data into ordinary cons/quote forms. A `,@`
;; splice emits %append (the load-time capture of `append`, core/10-list.lsp),
;; not the public `append`, so a cart that shadows `append` can't silently break
;; quasiquoted code (robustness contract — see core/40-ctrl.lsp). The expander
;; itself uses only kernel prims (atom/car/cdr/is/and/not/list) for the same
;; reason.

;; Nested quasiquote (a backquote inside a backquote) is NOT supported: the
;; expander has no nesting-depth tracking, so it would substitute inner
;; unquotes one level too early — silent wrong data. It raises loudly at
;; expansion time instead. Build inner templates with list/cons if needed.

(defn %qq (x)
  (if (atom x)
      (list 'quote x)
      (if (is (car x) 'unquote)
          (car (cdr x))
          (if (is (car x) 'quasiquote)
              (raise "quasiquote: nested quasiquote is not supported")
              (%qq-list x)))))

(defn %qq-list (xs)
  (if (atom xs)
      (%qq xs)
      (if (is (car xs) 'unquote)          ; dotted unquote tail: `(a . ,b)
          (car (cdr xs))
          (if (is (car xs) 'quasiquote)   ; dotted nested tail: `(a . `b)
              (raise "quasiquote: nested quasiquote is not supported")
              (if (is (car xs) 'unquote-splicing)
                  (raise "quasiquote: ,@ cannot appear in dotted tail position")
                  (if (and (not (atom (car xs)))
                           (is (car (car xs)) 'unquote-splicing))
                      (list '%append (car (cdr (car xs))) (%qq-list (cdr xs)))
                      (list 'cons (%qq (car xs)) (%qq-list (cdr xs)))))))))

(defmacro quasiquote (x)
  (%qq x))
