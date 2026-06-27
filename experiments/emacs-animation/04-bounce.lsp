;; 04-bounce — Torop Part 7's "runner" momentum, made autonomous.
;;
;; The original sets velocity (dx,dy) from arrow keys. KEC Lisp has no keyboard
;; input primitive yet, so we drop the keys and keep the physics: a ball carries
;; velocity and reflects off the walls. This is the experiment that proves the
;; velocity-integration model works; the keyboard version is blocked on a host
;; input seam (see README).

(load "experiments/emacs-animation/anim.lsp")

(define W 56)
(define H 22)
(define c (make-canvas W H " "))
(define x 1)
(define y 1)
(define dx 1)
(define dy 1)

(anim-loop 300 0.035
  (fn (i)
    (canvas-clear! c)
    (draw-char c x y "O")
    (render-frame c)
    (set x (+ x dx))
    (set y (+ y dy))
    (when (or (<= x 0) (>= x (- W 1))) (set dx (- 0 dx)))
    (when (or (<= y 0) (>= y (- H 1))) (set dy (- 0 dy)))))
