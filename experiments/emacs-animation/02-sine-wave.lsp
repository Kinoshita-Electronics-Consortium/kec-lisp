;; 02-sine-wave — Torop Part 4's "mathematical movement": (sin (/ y 7.0)).
;;
;; A travelling sine wave scrolls across the canvas. Each frame recomputes the
;; whole curve with a phase offset, so the wave appears to move. KEC Lisp's host
;; has no sin/cos, so this leans on anim-sin (our Bhaskara approximation) — the
;; clearest single argument for adding a host trig primitive (see README).

(load "experiments/emacs-animation/anim.lsp")

(define W 64)
(define H 21)
(define MID 10)        ; vertical centre row
(define AMP 9)         ; amplitude in rows
(define c (make-canvas W H " "))

(anim-loop 160 0.05
  (fn (i)
    (canvas-clear! c)
    (let x 0)
    (while (< x W)
      ;; spatial frequency /5.0, temporal phase * 0.25
      (let theta (+ (/ x 5.0) (* i 0.25)))
      (let y (+ MID (floor (* AMP (anim-sin theta)))))
      (draw-char c x (clamp y 0 (- H 1)) "*")
      (set x (+ x 1)))
    (render-frame c)))
