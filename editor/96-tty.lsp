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

;; (tty-screen b cols rows) -> the full screen as one string. The body window is
;; vertically scrolled so the CURSOR line is always visible (the same recompute-
;; and-persist scroll text-screen does in 32-text): the persisted buffer scroll
;; (slot 6, see 30-buffer) is pulled toward the cursor row when it drifts off
;; either edge, then written back so the view is stable across frames.
(defn tty-screen (b cols rows)
  (let recs (buffer->view-lines b))
  (let avail (if (< rows 3) 1 (- rows 2)))     ; leave room for modeline + echo
  ;; cursor row index within the view lines (iterative scan)
  (let cidx 0)
  (let i 0)
  (let rest recs)
  (while rest
    (when (view-line-cursor? (car rest)) (set cidx i))
    (set rest (cdr rest))
    (set i (+ i 1)))
  ;; recompute vertical scroll so the cursor row is on-screen, persist it
  (let scroll (buffer-scroll b))
  (if (< cidx scroll) (set scroll cidx))
  (if (<= (+ scroll avail) cidx) (set scroll (+ (- cidx avail) 1)))
  (if (< scroll 0) (set scroll 0))
  (vector-set! b 6 scroll)
  (let body (map (fn (rec) (%tty-tree-line rec cols)) (take (drop recs scroll) avail)))
  (string-append
    %REV (%tty-fit (string-append " " (buffer-modeline b) %TTY-HELP) cols) %RST "\n"
    (join body "\n") "\n"
    (%tty-fit (buffer-echo b) cols)))

(provide 'editor/tty)
