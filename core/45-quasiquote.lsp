;; KEC Core — quasiquote : macro construction without list/cons noise
;;
;; The reader maps:
;;   `x   -> (quasiquote x)
;;   ,x   -> (unquote x)
;;   ,@x  -> (unquote-splicing x)
;;
;; This macro expands quasiquoted data into ordinary cons/append/quote forms.

(defn %qq (x)
  (if (atom x)
      (list 'quote x)
      (if (and (not (atom x)) (is (car x) 'unquote))
          (nth x 1)
          (%qq-list x))))

(defn %qq-list (xs)
  (if (atom xs)
      (%qq xs)
      (if (and (not (atom (car xs)))
               (is (car (car xs)) 'unquote-splicing))
          (list 'append (nth (car xs) 1) (%qq-list (cdr xs)))
          (list 'cons (%qq (car xs)) (%qq-list (cdr xs))))))

(defmacro quasiquote (x)
  (%qq x))
