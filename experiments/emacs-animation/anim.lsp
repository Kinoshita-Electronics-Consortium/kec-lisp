;; anim.lsp — a tiny ASCII-animation playground for KEC Lisp.
;;
;; This is an EXPERIMENT, translating Dan Torop's "Emacs Lisp animations"
;; teaching project (https://dantorop.info/project/emacs-animation/) into KEC
;; Lisp semantics. Torop animates ASCII in an Emacs *buffer* with the loop
;;   (while ...  (erase-buffer) (insert ...) (sit-for 0.2))
;; KEC Lisp has no buffer/sit-for/read-event, so we animate the TERMINAL
;; directly: ANSI cursor control + a spin-wait clock + a mutable char canvas.
;;
;; What this maps onto (the "what's missing" list, see README):
;;   erase-buffer / insert  ->  a canvas + (draw-char c x y ch) over ANSI
;;   sit-for 0.2            ->  (anim-delay 0.2)  [spin-wait on (clock)]
;;   (sin (/ y 7.0))        ->  (anim-sin x)      [host has no sin/cos]
;;   read-event (keyboard)  ->  NOT POSSIBLE yet  [no host input primitive]
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
;; (clock) is CPU seconds; spinning consumes CPU, so the busy-wait tracks ~wall
;; time at the cost of pinning one core. Fine for an experiment; a real design
;; system wants a host `sleep`/idle-timer instead (see README).
;; ---------------------------------------------------------------------------
(defn anim-delay (secs)
  (let t0 (clock))
  (while (< (- (clock) t0) secs) nil))

;; ---------------------------------------------------------------------------
;; Math the host doesn't give us.
;; No sin/cos primitive, so approximate sine with the Bhaskara/parabola form,
;; reduced to [-PI, PI]. Max error ~0.06 — invisible at character resolution.
;; ---------------------------------------------------------------------------
(define PI    3.14159265)
(define TWOPI 6.2831853)

(defn anim-sin (x)
  (let r (- (mod (+ x PI) TWOPI) PI))             ; wrap into [-PI, PI]
  ;; base parabola: (4/PI)r - (4/PI^2) r|r|  — exact at 0, +-PI/2, +-PI
  (let base (- (* (/ 4 PI) r) (* (/ 4 (* PI PI)) r (abs r))))
  ;; Q=0.225 refinement: pulls the mid-curve toward true sine (peaks stay exact)
  (+ base (* 0.225 (- (* base (abs base)) base))))

(defn anim-cos (x) (anim-sin (+ x (/ PI 2))))

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
