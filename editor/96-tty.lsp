;; KEC Lisp editor tier — tty : the terminal painter for the structural editor.
;;
;; The terminal host layer (ANSI), distinct from the abstract view model in
;; 40-view (`buffer->view-lines`, which carries no terminal vocabulary). This
;; turns those line records into one ANSI screen string the `kec edit` subcommand
;; prints each frame: an inverted modeline, the structural tree (the cursor line
;; in reverse video), clipped to the height, and the echo line.
;;
;; Load order: after 40-view and 95-host.

(define %ESC (char->string 27))
(define %REV (string-append %ESC "[7m"))      ; reverse video on
(define %RST (string-append %ESC "[0m"))      ; reset

(defn %tty-fit (s cols)
  (if (<= (string-length s) cols) s (substring s 0 cols)))

(defn %tty-tree-line (rec cols)
  (let txt (%tty-fit (string-append (string-repeat "  " (view-line-depth rec))
                                    (view-line-label rec))
                     cols))
  (if (view-line-cursor? rec) (string-append %REV txt %RST) txt))

;; The help strip lists ONLY keys bound in editor/55-bindings — never advertise
;; a key the dispatcher can't resolve. (The former C-M-f/b, C-M-d/u, C-M-k,
;; M-(, and "C-x C-e eval" entries were bound nowhere.)
;; TODO: 'eval-current is declared a host command in editor/55-bindings.lsp but
;; no host wires it yet (needs cli/main.c); bind + re-advertise "C-x C-e eval"
;; here once a host performs it.
(define %TTY-HELP
  (string-append
    "  C-n/C-p line  C-f/C-b char  C-w kill  C-y yank  "
    "C-/ undo  C-x C-s save  C-x C-c exit"))

;; (tty-screen b cols rows) -> the full screen as one string.
(defn tty-screen (b cols rows)
  (let body (map (fn (rec) (%tty-tree-line rec cols)) (buffer->view-lines b)))
  (let avail (if (< rows 3) 1 (- rows 2)))     ; leave room for modeline + echo
  (string-append
    %REV (%tty-fit (string-append " " (buffer-modeline b) %TTY-HELP) cols) %RST "\n"
    (join (take body avail) "\n") "\n"
    (%tty-fit (buffer-echo b) cols)))

(provide 'editor/tty)
