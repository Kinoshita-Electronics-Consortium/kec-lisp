;; anim.lsp — a tiny ASCII-animation playground for KEC Lisp.
;;
;; This is an EXPERIMENT, translating Dan Torop's "Emacs Lisp animations"
;; teaching project (https://dantorop.info/project/emacs-animation/) into KEC
;; Lisp semantics. Torop animates ASCII in an Emacs *buffer* with the loop
;;   (while ...  (erase-buffer) (insert ...) (sit-for 0.2))
;; KEC Lisp has no buffer/sit-for/read-event, so we animate the TERMINAL
;; directly: ANSI cursor control + a spin-wait clock + a mutable char canvas.
;;
;; What this maps onto:
;;   erase-buffer / insert  ->  a canvas + (draw-char c x y ch) over ANSI
;;   sit-for 0.2            ->  (anim-delay 0.2)  [spin-wait on (now), ADR-0005]
;;   (sin (/ y 7.0))        ->  (anim-sin x)      [host-native sin/cos, ADR-0005]
;;   read-event (keyboard)  ->  read-key / poll-key  [PR2 — see README]
;;
;; Load it from a demo with:  (load "experiments/emacs-animation/anim.lsp")
;; and run the demo from the repo root:  ./build/kec run experiments/emacs-animation/02-sine-wave.lsp
;; Run it in a REAL terminal — frames flush on the newline at end of each frame,
;; which only happens line-by-line on a TTY (a pipe block-buffers).

;; ---------------------------------------------------------------------------
;; ANSI terminal control
;; ---------------------------------------------------------------------------
(define ESC (char->string 27))
(define CSI (string-append ESC "["))

(defn ansi-clear ()       (string-append CSI "2J"))   ; erase whole screen
(defn ansi-home ()        (string-append CSI "H"))    ; cursor to row 1 col 1
(defn ansi-hide-cursor () (string-append CSI "?25l"))
(defn ansi-show-cursor () (string-append CSI "?25h"))

;; (ansi-goto row col) — 1-based, like Emacs goto-line/move-to-column.
(defn ansi-goto (row col)
  (string-append CSI (number->string row) ";" (number->string col) "H"))

;; ---------------------------------------------------------------------------
;; Timing — the sit-for replacement.
;; (now) is monotonic wall-clock seconds (ADR-0005). The busy-wait still pins
;; one core; true CPU relief comes from the host idle-timer (PR3), not here —
;; but (now) measures real elapsed time correctly regardless of CPU load.
;; ---------------------------------------------------------------------------
(defn anim-delay (secs)
  (let t0 (now))
  (while (< (- (now) t0) secs) nil))

;; ---------------------------------------------------------------------------
;; Math — now host-native (ADR-0005 added real sin/cos + pi/tau). anim-sin /
;; anim-cos delegate straight to the host primitives; the Bhaskara approximation
;; this file used to carry (when the host had no trig) is gone.
;; ---------------------------------------------------------------------------
(define PI    pi)    ; kept as aliases for any caller; pi/tau are the canonical
(define TWOPI tau)   ; Core constants now

(defn anim-sin (x) (sin x))
(defn anim-cos (x) (cos x))

;; (clamp v lo hi)
(defn clamp (v lo hi) (max lo (min hi v)))

;; ---------------------------------------------------------------------------
;; The canvas — a mutable w*h grid of 1-char strings. This is the reusable core:
;; draw-char / clear-char / canvas-clear! mirror Torop's grid helpers exactly.
;; ---------------------------------------------------------------------------
(defn make-canvas (w h blank)
  (vector w h blank (make-vector (* w h) blank)))

(defn canvas-w     (c) (vector-ref c 0))
(defn canvas-h     (c) (vector-ref c 1))
(defn canvas-blank (c) (vector-ref c 2))
(defn canvas-cells (c) (vector-ref c 3))

(defn in-bounds? (c x y)
  (and (>= x 0) (< x (canvas-w c)) (>= y 0) (< y (canvas-h c))))

;; (draw-char c x y ch) — set cell (x,y); out-of-bounds is a silent no-op.
(defn draw-char (c x y ch)
  (when (in-bounds? c x y)
    (vector-set! (canvas-cells c) (+ x (* y (canvas-w c))) ch))
  c)

(defn clear-char (c x y) (draw-char c x y (canvas-blank c)))

;; (canvas-clear! c) — the erase-buffer for one canvas.
(defn canvas-clear! (c)
  (let cells (canvas-cells c))
  (let n (* (canvas-w c) (canvas-h c)))
  (let blank (canvas-blank c))
  (let i 0)
  (while (< i n) (vector-set! cells i blank) (set i (+ i 1)))
  c)

;; (canvas->string c) — render to one frame string (rows joined by newline,
;; y=0 at the top, terminal-natural).
(defn canvas->string (c)
  (let w (canvas-w c))
  (let h (canvas-h c))
  (let cells (canvas-cells c))
  (let out "")
  (let y 0)
  (while (< y h)
    (let x 0)
    (while (< x w)
      (set out (string-append out (vector-ref cells (+ x (* y w)))))
      (set x (+ x 1)))
    (when (< y (- h 1)) (set out (string-append out "\n")))
    (set y (+ y 1)))
  out)

;; (render-frame c) — paint a canvas in place (home, no full clear → low flicker).
(defn render-frame (c)
  (princ (ansi-home))
  (princ (canvas->string c))
  (newline))

;; ---------------------------------------------------------------------------
;; The frame loop — the one thing every demo shares (Torop's `while` + sit-for).
;; (anim-loop n delay body) calls (body i) for i in 0..n-1, delaying between
;; frames, with cursor hidden and the screen cleared once up front.
;; ---------------------------------------------------------------------------
(defn screen-begin ()
  (princ (ansi-hide-cursor)) (princ (ansi-clear)) (princ (ansi-home)))

(defn screen-end ()
  (princ (ansi-show-cursor)) (newline))

(defn anim-loop (n delay body)
  (screen-begin)
  (let i 0)
  (while (< i n)
    (body i)
    (anim-delay delay)
    (set i (+ i 1)))
  (screen-end))
