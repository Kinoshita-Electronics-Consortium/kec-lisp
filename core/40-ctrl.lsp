;; KEC Core — ctrl : control macros
;;
;; Kernel ships if/and/or/do/while. Core adds the macros every real program
;; reaches for. Fe has no quasiquote, so expansions are built by hand with
;; list/cons/append; gensym (a host primitive) keeps loop temporaries from
;; capturing user names.

;; (when test body...)   -> (if test (do body...) nil)
(set when (mac (test . body)
  (list 'if test (cons 'do body) nil)))

;; (unless test body...) -> (if test nil (do body...))
(set unless (mac (test . body)
  (list 'if test nil (cons 'do body))))

;; (cond (test body...)... ) — first truthy test wins; `else` = catch-all.
(set %cond-expand (fn (clauses)
  (if (nil? clauses)
      nil
      (do
        (let clause (car clauses))
        (let test (car clause))
        (let body (cons 'do (cdr clause)))
        (if (is test 'else)
            body
            (list 'if test body (%cond-expand (cdr clauses))))))))
(set cond (mac clauses (%cond-expand clauses)))

;; (case key (vals body...)... ) — is-match key against each clause's
;; value(s); a clause value may be one datum or a list of data. `else` wins.
(set %case-expand (fn (kv clauses)
  (if (nil? clauses)
      nil
      (do
        (let clause (car clauses))
        (let vals (car clause))
        (let body (cons 'do (cdr clause)))
        (if (is vals 'else)
            body
            (do
              (let valset (if (pair? vals) vals (list vals)))
              (list 'if
                    (list 'member kv (list 'quote valset))
                    body
                    (%case-expand kv (cdr clauses)))))))))
(set case (mac (key . clauses)
  (let kv (gensym))
  (list 'do
    (list 'let kv key)
    (%case-expand kv clauses))))

;; (let* ((s v)...) body...) — sequential bindings (kernel let is single-pair).
(set %let*-binds (fn (binds)
  (if (nil? binds)
      nil
      (cons (list 'let (car (car binds)) (nth (car binds) 1))
            (%let*-binds (cdr binds))))))
(set let* (mac (binds . body)
  (cons 'do (append (%let*-binds binds) body))))

;; (letrec ((s v)...) body...) — mutually-recursive locals: declare all to
;; nil, then assign (so each value form can reference the others).
(set %letrec-decls (fn (binds)
  (if (nil? binds)
      nil
      (cons (list 'let (car (car binds)) nil)
            (%letrec-decls (cdr binds))))))
(set %letrec-sets (fn (binds)
  (if (nil? binds)
      nil
      (cons (list 'set (car (car binds)) (nth (car binds) 1))
            (%letrec-sets (cdr binds))))))
(set letrec (mac (binds . body)
  (cons 'do (append (%letrec-decls binds) (append (%letrec-sets binds) body)))))

;; (dotimes (i n) body...) — i from 0 to n-1.
(set dotimes (mac (spec . body)
  (let var (car spec))
  (let cnt (nth spec 1))
  (let lim (gensym))
  (list 'do
    (list 'let lim cnt)
    (list 'let var 0)
    (append (list 'while (list '< var lim))
            (append body (list (list 'set var (list '+ var 1))))))))

;; (dolist (x xs) body...) — bind x over xs.
(set dolist (mac (spec . body)
  (let var (car spec))
  (let lst (nth spec 1))
  (let cur (gensym))
  (list 'do
    (list 'let cur lst)
    (append (list 'while cur)
            (append (list (list 'let var (list 'car cur)))
                    (append body (list (list 'set cur (list 'cdr cur)))))))))

;; (begin body...) — alias for the kernel do sequence.
(set begin (mac body (cons 'do body)))
