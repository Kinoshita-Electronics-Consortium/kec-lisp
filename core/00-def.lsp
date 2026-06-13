;; KEC Core — def : ergonomic definition macros (standard §4.5)
;;
;; The Fe Kernel has no define/defun/defmacro — only `set` and `fn`/`mac`.
;; These three macros are the ground floor every other Core module builds on,
;; so this file loads first. They expand to plain `(set name (fn ...))` shapes.

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
