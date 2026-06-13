;; KEC Core — def : ergonomic definition macros (standard §4.5)
;;
;; The Fe Kernel has no define/defun/defmacro — only `=` and `fn`/`mac`.
;; These three macros are the ground floor every other Core module builds on,
;; so this file loads first. They expand to plain `(= name (fn ...))` shapes.

;; (defn name (params...) body...)  ->  (= name (fn (params...) body...))
(= defn (mac (name params . body)
  (list '= name (cons 'fn (cons params body)))))

;; (defmacro name (params...) body...) -> (= name (mac (params...) body...))
(= defmacro (mac (name params . body)
  (list '= name (cons 'mac (cons params body)))))

;; (define name value)        -> (= name value)
;; (define (f args...) body)  -> (= f (fn (args...) body))   ; Scheme-style sugar
(= define (mac (head . body)
  (if (atom head)
      (list '= head (car body))
      (list '= (car head) (cons 'fn (cons (cdr head) body))))))
