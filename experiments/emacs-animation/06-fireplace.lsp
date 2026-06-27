;; 06-fireplace — johanvts/emacs-fireplace, reimagined for the KN-86.
;;
;;   https://github.com/johanvts/emacs-fireplace
;;
;; The original draws flames at fixed positions whose lower part swells and upper
;; part randomly shrinks (the flicker), in TWO colours: an outer "orange red" and
;; an inner "dark orange" hot core, with '*' smoke drifting above.
;;
;; Two changes for the KN-86, per the brief:
;;   * ONE colour — the canonical amber #E6A020 on black (Canonical Hardware Spec).
;;   * The inner/outer two-tone becomes a SHADE RAMP: " ░▒▓█". Heat intensity that
;;     the original carried in colour, we carry in glyph density. Hot core = █,
;;     cooling toward the edges and tips through ▓ ▒ ░ to black.
;;
;; The motion is a heat field (the "doom fire" propagation): a hot base reseeded
;; each frame, heat climbing upward with random cooling + lateral drift. Flames
;; are seeded at several x-positions — emacs-fireplace's `fireplace--flame-pos`.
;;
;; Run from the repo root, in a real terminal:
;;   ./build/kec run experiments/emacs-animation/06-fireplace.lsp

(load "experiments/emacs-animation/anim.lsp")

;; ---- geometry & palette ---------------------------------------------------
(define FW 64)                 ; hearth width  (cells)
(define FH 26)                 ; hearth height (cells)
(define HMAX 16)               ; heat at a flame core

;; amber fg + black bg, set once per frame and reset at the end of it.
(define AMBER (string-append CSI "38;2;230;160;32;48;2;0;0;0m"))
(define RESET (string-append CSI "0m"))

;; heat -> shade glyph. The whole point: one colour, intensity via density.
(defn heat->glyph (v)
  (cond ((<= v 0) " ")
        ((<= v 3) "░")
        ((<= v 6) "▒")
        ((<= v 9) "▓")
        (t        "█")))

;; ---- heat field -----------------------------------------------------------
(define heat (make-vector (* FW FH) 0))
(defn hidx (x y) (+ x (* y FW)))
(defn hget (x y) (vector-ref heat (hidx x y)))
(defn hset (x y v) (vector-set! heat (hidx x y) v))

;; flame x-positions (relative 0..1) — cf. fireplace--flame-pos.
(define FLAMES (list 0.5 0.34 0.66 0.2 0.8))

;; (seed-base) — relight the bottom row each frame: a warm ember bed everywhere,
;; plus hotter triangular flame columns at the flame positions, all flickering.
(defn seed-base ()
  (let bottom (- FH 1))
  (let x 0)
  (while (< x FW)
    (hset x bottom (+ 1 (rand-int 2)))           ; faint ember bed (1..2 -> ░)
    (set x (+ x 1)))
  (for-each
    (fn (p)
      (let cx (floor (* p FW)))
      (let half (+ 2 (rand-int 3)))              ; flame half-width 2..4
      (let dx (- 0 half))
      (while (<= dx half)
        (let xx (clamp (+ cx dx) 0 (- FW 1)))
        (let h (- HMAX (abs dx)))                ; triangular: hottest at centre
        (let v (clamp (+ h (- (rand-int 3) 1)) 0 HMAX))
        (hset xx bottom (max (hget xx bottom) v))
        (set dx (+ dx 1))))
    FLAMES))

;; (propagate) — climb heat up one row, cooling and drifting sideways. Reads row
;; y, writes row y-1; the bottom row is the (reseeded) source, so the fire rises.
(defn propagate ()
  (let x 0)
  (while (< x FW)
    (let y 1)
    (while (< y FH)
      (let src (hget x y))
      (if (<= src 0)
          (hset x (- y 1) 0)
          (do
            (let dr (rand-int 3))                ; drift -1/0/+1
            (let cl (rand-int 3))                ; cooling 0/1/2, avg 1 per row
            (let tx (clamp (+ x (- dr 1)) 0 (- FW 1)))
            (hset tx (- y 1) (max 0 (- src cl)))))
      (set y (+ y 1)))
    (set x (+ x 1))))

;; (fire-frame) — one amber frame string from the heat field.
(defn fire-frame ()
  (let out AMBER)
  (let y 0)
  (while (< y FH)
    (let x 0)
    (while (< x FW)
      (set out (string-append out (heat->glyph (hget x y))))
      (set x (+ x 1)))
    (when (< y (- FH 1)) (set out (string-append out "\n")))
    (set y (+ y 1)))
  (string-append out RESET))

;; ---- run (gated so a probe can load the engine headless) ------------------
(unless (bound? 'FIRE-NORUN)
  (set-seed! (floor (+ 1 (* 100000 (clock)))))
  (anim-loop 300 0.08
    (fn (i)
      (seed-base)
      (propagate)
      (princ (ansi-home))
      (princ (fire-frame))
      (newline))))
