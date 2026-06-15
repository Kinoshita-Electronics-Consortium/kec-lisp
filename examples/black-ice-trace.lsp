;; BLACK ICE TRACE — command-driven terminal hacking game.
;;
;; Try:
;;   ./build/kec run examples/black-ice-trace.lsp new
;;   ./build/kec run examples/black-ice-trace.lsp scan
;;   ./build/kec run examples/black-ice-trace.lsp crack
;;   ./build/kec run examples/black-ice-trace.lsp siphon
;;   ./build/kec run examples/black-ice-trace.lsp pivot 2

(apply load
       (list (if (file-exists? "examples/black-ice-trace-lib.lsp")
                 "examples/black-ice-trace-lib.lsp"
                 "black-ice-trace-lib.lsp")))

(let bit-save-path ".black-ice-trace-save.lsp")

(defn bit-load-state ()
  (if (file-exists? bit-save-path)
      (read-string (read-file bit-save-path))
      (bit-new-state)))

(defn bit-save-state (state)
  (write-file bit-save-path (repr state)))

(defn bit-run-command (argv)
  (let words (cdr argv))
  (let command (if words (bit-command-symbol (car words)) 'status))
  (let value (if (and words (cdr words)) (string->number (car (cdr words))) 0))
  (cond
    ((is command 'help)
     (princ (bit-help-text)) (newline))
    ((is command 'new)
     (let state (bit-new-state))
     (bit-save-state state)
     (bit-print-render state))
    (else
      (let state (bit-load-state))
      (set state (bit-apply-command state command value))
      (bit-save-state state)
      (bit-print-render state))))

(bit-run-command (args))
