;; 03-drunkard — Torop Part 7's drunkard's walk.
;;
;; The Emacs original moves a '*' by (1- (random 3)) on each axis — i.e. -1, 0,
;; or +1 — drawing, pausing, clearing, repeating. We keep a '.' trail so the wander
;; is visible. rand-int 3 → {0,1,2}; subtract 1 → {-1,0,+1}, exactly Torop's step.

(load "experiments/emacs-animation/anim.lsp")

(define W 50)
(define H 22)
(define c (make-canvas W H " "))
(define x (floor (/ W 2)))
(define y (floor (/ H 2)))

(anim-loop 320 0.05
  (fn (i)
    (draw-char c x y "*")          ; head at current position
    (render-frame c)
    (draw-char c x y ".")          ; leave a trail where the head was
    (set x (clamp (+ x (- (rand-int 3) 1)) 0 (- W 1)))
    (set y (clamp (+ y (- (rand-int 3) 1)) 0 (- H 1)))))
