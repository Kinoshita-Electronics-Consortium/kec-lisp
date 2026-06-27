;; 01-line-down — Torop Part 4, the first animation: a line walks down the page.
;;
;; The literal Emacs original:
;;   (dotimes (line 10) (erase-buffer) (dotimes (y line) (newline))
;;                      (insert "----------------") (sit-for 0.2))
;; Here we draw straight to the terminal: at frame i, print the bar on row i and
;; full-width spaces everywhere else (spaces = our erase, so the old bar is wiped).
;; This is the low-level idiom — no canvas — to show the bones of the technique.

(load "experiments/emacs-animation/anim.lsp")

(define W 44)
(define H 18)
(define BAR   (string-repeat "-" W))
(define BLANK (string-repeat " " W))

(anim-loop H 0.12
  (fn (i)
    (princ (ansi-home))
    (let y 0)
    (while (< y H)
      (princ (if (is y i) BAR BLANK))
      (newline)
      (set y (+ y 1)))))
