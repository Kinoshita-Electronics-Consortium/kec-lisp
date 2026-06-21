;; KEC Core — ctrl : control macros
;;
;; Kernel ships if/and/or/do/while. Core adds the macros every real program
;; reaches for. This module loads before quasiquote, so its expansions are still
;; built by hand with list/cons; gensym (a host primitive) keeps loop
;; temporaries from capturing user names.
;;
;; ROBUSTNESS CONTRACT (AMOP §4.2.2, "Overriding the Standard Method", pp.
;; 112-113): a Core macro must bottom out on FROZEN KERNEL primitives only —
;; both in the code it *emits* and in its own *expander* — never on a shadowable
;; public Core function (member / nth / append / nil? / pair? / ...). Otherwise a
;; cart redefining such a name would silently corrupt the macro. So the
;; expanders below use only kernel prims (cons car cdr list if not is atom
;; < + quote do let set while or) plus gensym: they index with car/cdr (not
;; `nth`), thread accumulators (not `append`), and test emptiness with `not`
;; (not `nil?`). See tests/core/macro-robustness.lsp and docs/language.md
;; "Load-bearing prelude (do not shadow)".

;; (when test body...)   -> (if test (do body...) nil)
(set when (mac (test . body)
  (list 'if test (cons 'do body) nil)))

;; (unless test body...) -> (if test nil (do body...))
(set unless (mac (test . body)
  (list 'if test nil (cons 'do body))))

;; (cond (test body...)... ) — first truthy test wins; `else` = catch-all.
(set %cond-expand (fn (clauses)
  (if (not clauses)
      nil
      (do
        (let clause (car clauses))
        (let test (car clause))
        (let body (cons 'do (cdr clause)))
        (if (is test 'else)
            body
            (list 'if test body (%cond-expand (cdr clauses))))))))
(set cond (mac clauses (%cond-expand clauses)))

;; (case key (vals body...)... ) — is-match key against each clause's value(s);
;; a clause value may be one datum or a list of data. `else` wins. Expands to an
;; (or (is tmp 'v1) (is tmp 'v2) ...) chain rather than calling `member`, so the
;; expansion never rides on a shadowable function.
(set %case-tests (fn (tmp vals)
  (if (not vals)
      nil
      (cons (list 'is tmp (list 'quote (car vals)))
            (%case-tests tmp (cdr vals))))))
(set %case-expand (fn (tmp clauses)
  (if (not clauses)
      nil
      (do
        (let clause (car clauses))
        (let vals (car clause))
        (let body (cons 'do (cdr clause)))
        (if (is vals 'else)
            body
            (do
              (let valset (if (atom vals) (list vals) vals))
              (list 'if
                    (cons 'or (%case-tests tmp valset))
                    body
                    (%case-expand tmp (cdr clauses)))))))))
(set case (mac (key . clauses)
  (let tmp (gensym))
  (list 'do
    (list 'let tmp key)
    (%case-expand tmp clauses))))

;; (let* ((s v)...) body...) — sequential bindings (kernel let is single-pair).
;; The body is threaded into the recursion tail, so no `append` is needed.
(set %let*-binds (fn (binds body)
  (if (not binds)
      body
      (cons (list 'let (car (car binds)) (car (cdr (car binds))))
            (%let*-binds (cdr binds) body)))))
(set let* (mac (binds . body)
  (cons 'do (%let*-binds binds body))))

;; (letrec ((s v)...) body...) — mutually-recursive locals: declare all to
;; nil, then assign (so each value form can reference the others). Both phases
;; thread their tail, so no `append` is needed.
(set %letrec-sets (fn (binds tail)
  (if (not binds)
      tail
      (cons (list 'set (car (car binds)) (car (cdr (car binds))))
            (%letrec-sets (cdr binds) tail)))))
(set %letrec-decls (fn (binds tail)
  (if (not binds)
      tail
      (cons (list 'let (car (car binds)) nil)
            (%letrec-decls (cdr binds) tail)))))
(set letrec (mac (binds . body)
  (cons 'do (%letrec-decls binds (%letrec-sets binds body)))))

;; (dotimes (i n) body...) — i from 0 to n-1. The body is wrapped in one `do`
;; so the emitted `while` has a fixed shape and needs no `append`.
(set dotimes (mac (spec . body)
  (let var (car spec))
  (let lim (gensym))
  (list 'do
    (list 'let lim (car (cdr spec)))
    (list 'let var 0)
    (list 'while (list '< var lim)
          (cons 'do body)
          (list 'set var (list '+ var 1))))))

;; (dolist (x xs) body...) — bind x over xs.
(set dolist (mac (spec . body)
  (let var (car spec))
  (let cur (gensym))
  (list 'do
    (list 'let cur (car (cdr spec)))
    (list 'while cur
          (cons 'do (cons (list 'let var (list 'car cur)) body))
          (list 'set cur (list 'cdr cur))))))

;; (begin body...) — alias for the kernel do sequence.
(set begin (mac body (cons 'do body)))
