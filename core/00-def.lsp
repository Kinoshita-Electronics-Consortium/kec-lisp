;; KEC Core — def : ergonomic definition macros
;;
;; The kernel has no define/defun/defmacro — only `set` and `fn`/`mac`. These
;; load first because the other modules use them; they expand to `(set name ...)`
;; shapes wrapped so the form returns the thing it defined.
;;
;; `set` itself returns nil, so each macro evaluates `name` last (via `do`) to
;; hand the binding back — the function, macro, or value. That makes definitions
;; chainable and gives the REPL something useful to echo instead of nil. The
;; `set` keeps its exact scoping (top-level global / existing binding); only the
;; return value changes.

;; (defn name (params...) body...)  ->  define name as a fn, return the fn
(set defn (mac (name params . body)
  (list 'do (list 'set name (cons 'fn (cons params body))) name)))

;; (defmacro name (params...) body...) -> define name as a macro, return it
(set defmacro (mac (name params . body)
  (list 'do (list 'set name (cons 'mac (cons params body))) name)))

;; (define name value)        -> set name to value, return the value
;; (define (f args...) body)  -> define f as a fn, return the fn  ; Scheme sugar
(set define (mac (head . body)
  (if (atom head)
      (list 'do (list 'set head (car body)) head)
      (list 'do (list 'set (car head) (cons 'fn (cons (cdr head) body))) (car head)))))
