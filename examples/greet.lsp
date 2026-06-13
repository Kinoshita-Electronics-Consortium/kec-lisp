;; Reads command-line args (FULL profile).  Try:
;;   kec run examples/greet.lsp Ada Grace Lin
(let names (cdr (args)))               ; arg 0 is the script path
(if (nil? names)
    (do (princ "usage: kec run greet.lsp NAME...") (newline))
    (for-each
      (fn (n) (princ (format "Hello, %s!" n)) (newline))
      names))
