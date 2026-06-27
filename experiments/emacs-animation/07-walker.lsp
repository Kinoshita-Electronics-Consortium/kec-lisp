;; 07-walker — Torop Part 7's keyboard walker, now possible (read-key, PR2).
;;
;; Move '@' with W/A/S/D; Q quits. This is the interactive animation that was
;; blocked when the experiment started — `read-key` reads one input byte (nil at
;; end-of-input), so a key becomes a step.
;;
;; Under `kec run`, stdin is line-buffered (a plain script can't set raw mode),
;; so type a run of moves then Enter: "wasd<Enter>" steps four times (the Enter
;; byte, code 10, matches no direction and is ignored). One-keypress-per-step
;; real-time control needs raw mode — that arrives with the knEmacs idle-timer
;; (PR3). The read-key mechanism is identical either way.

(load "experiments/emacs-animation/anim.lsp")

(define W 40)
(define H 14)
(define c (make-canvas W H "."))
(define px (floor (/ W 2)))
(define py (floor (/ H 2)))

(defn draw ()
  (canvas-clear! c)
  (draw-char c px py "@")
  (princ (ansi-home))
  (princ (canvas->string c))
  (newline)
  (princ "WASD move, Q quit   @ = (")
  (princ (number->string px)) (princ ",") (princ (number->string py))
  (princ ")    ") (newline))

(screen-begin)
(draw)
(define go t)
(while go
  (let k (read-key))
  (if (nil? k)
      (set go nil)                                                  ; EOF -> exit
      (do
        (cond
          ((or (is k 119) (is k 87)) (set py (clamp (- py 1) 0 (- H 1))))  ; w up
          ((or (is k 115) (is k 83)) (set py (clamp (+ py 1) 0 (- H 1))))  ; s down
          ((or (is k 97)  (is k 65)) (set px (clamp (- px 1) 0 (- W 1))))  ; a left
          ((or (is k 100) (is k 68)) (set px (clamp (+ px 1) 0 (- W 1))))  ; d right
          ((or (is k 113) (is k 81)) (set go nil)))                       ; q quit
        (when go (draw)))))
(screen-end)
