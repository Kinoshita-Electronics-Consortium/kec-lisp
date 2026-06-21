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

(defn %qq (x)
  (if (atom x)
      (list 'quote x)
      (if (and (not (atom x)) (is (car x) 'unquote))
          (car (cdr x))
          (%qq-list x))))

(defn %qq-list (xs)
  (if (atom xs)
      (%qq xs)
      (if (and (not (atom (car xs)))
               (is (car (car xs)) 'unquote-splicing))
          (list '%append (car (cdr (car xs))) (%qq-list (cdr xs)))
          (list 'cons (%qq (car xs)) (%qq-list (cdr xs))))))

(defmacro quasiquote (x)
  (%qq x))
