;; KEC Core — def : ergonomic definition macros
;;
;; The kernel has no define/defun/defmacro — only `set` and `fn`/`mac`. These
;; load first because the other modules use them; they expand to plain
;; `(set name (fn ...))` shapes.

;; (defn name (params...) body...)  ->  (set name (fn (params...) body...))
(set defn (mac (name params . body)
  (list 'set name (cons 'fn (cons params body)))))

;; (defmacro name (params...) body...) -> (set name (mac (params...) body...))
(set defmacro (mac (name params . body)
  (list 'set name (cons 'mac (cons params body)))))

;; (define name value)        -> (set name value)
;; (define (f args...) body)  -> (set f (fn (args...) body))   ; Scheme-style sugar
(set define (mac (head . body)
  (if (atom head)
      (list 'set head (car body))
      (list 'set (car head) (cons 'fn (cons (cdr head) body))))))
