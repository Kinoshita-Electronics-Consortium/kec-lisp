;; Conway's Game of Life in KEC Lisp
;;
;; Board: a flat list of 0/1 values, row-major (W columns × H rows).
;; Cell (col, row) lives at index (+ (* row W) col).
;;
;; Run:  kec run examples/life.lsp
;;
;; Adjust W, H, and GENS below.  Larger grids run slower because neighbour
;; lookup uses nth, which is O(index) over a list.

(let W 30)
(let H 15)
(let GENS 20)

;; -----------------------------------------------------------------------
;; Grid primitives
;; -----------------------------------------------------------------------

;; Empty W×H grid, all cells dead.
(defn make-grid (w h)
  (let g nil)
  (dotimes (i (* w h)) (set g (cons 0 g)))
  g)

;; Value of cell (col, row).  Returns 0 for out-of-bounds.
(defn grid-ref (grid w h col row)
  (if (or (< col 0) (>= col w) (< row 0) (>= row h))
    0
    (nth grid (+ (* row w) col))))

;; New grid with cell (col, row) set to val (functional — no mutation).
(defn grid-set (grid w col row val)
  (let idx (+ (* row w) col))
  (let acc nil)
  (let i   0)
  (let cur grid)
  (while cur
    (set acc (cons (if (= i idx) val (car cur)) acc))
    (set cur (cdr cur))
    (set i   (+ i 1)))
  (reverse acc))

(defn grid-on (grid w col row)
  (grid-set grid w col row 1))

;; Count live cells (used for the population display).
(defn count-live (grid)
  (let n 0)
  (dolist (c grid) (when (= c 1) (set n (+ n 1))))
  n)

;; -----------------------------------------------------------------------
;; Simulation — Conway's rules
;;   live cell with 2 or 3 live neighbours survives
;;   dead cell with exactly 3 live neighbours is born
;;   all other cells die / stay dead
;; -----------------------------------------------------------------------

(defn count-neighbors (grid w h col row)
  (let n  0)
  (let dr -1)
  (let dc -1)
  (while (<= dr 1)
    (set dc -1)
    (while (<= dc 1)
      (when (not (and (= dr 0) (= dc 0)))
        (set n (+ n (grid-ref grid w h (+ col dc) (+ row dr)))))
      (set dc (+ dc 1)))
    (set dr (+ dr 1)))
  n)

;; Return the next generation.
(defn step (grid w h)
  (let orig  grid)
  (let cur   grid)
  (let next  nil)
  (let row   0)
  (let col   0)
  (let n     0)
  (let alive 0)
  (while cur
    (set n     (count-neighbors orig w h col row))
    (set alive (car cur))
    (set next (cons
      (if (= alive 1)
        (if (or (= n 2) (= n 3)) 1 0)
        (if (= n 3) 1 0))
      next))
    (set cur (cdr cur))
    (set col (+ col 1))
    (when (= col w)
      (set col 0)
      (set row (+ row 1))))
  (reverse next))

;; -----------------------------------------------------------------------
;; Display
;; -----------------------------------------------------------------------

(defn display-grid (grid w gen)
  (princ "Gen ") (princ gen)
  (princ "  pop ") (princ (count-live grid))
  (newline)
  (let cur grid)
  (let col 0)
  (while cur
    (princ (if (= (car cur) 1) "#" "."))
    (set cur (cdr cur))
    (set col (+ col 1))
    (when (= col w)
      (newline)
      (set col 0)))
  (newline))

;; -----------------------------------------------------------------------
;; Patterns (each returns a new grid with the pattern placed at offset ox,oy)
;; -----------------------------------------------------------------------

;; Glider — moves one cell diagonally every 4 generations:
;;   .#.
;;   ..#
;;   ###
(defn place-glider (grid w ox oy)
  (let g (grid-on grid w (+ ox 1) oy))
  (set g (grid-on g  w (+ ox 2) (+ oy 1)))
  (set g (grid-on g  w ox       (+ oy 2)))
  (set g (grid-on g  w (+ ox 1) (+ oy 2)))
  (set g (grid-on g  w (+ ox 2) (+ oy 2)))
  g)

;; Blinker — period-2 oscillator:  ###
(defn place-blinker (grid w ox oy)
  (let g (grid-on grid w ox       oy))
  (set g (grid-on g  w (+ ox 1)  oy))
  (set g (grid-on g  w (+ ox 2)  oy))
  g)

;; 2×2 block — still life:  ##
;;                          ##
(defn place-block (grid w ox oy)
  (let g (grid-on grid w ox       oy))
  (set g (grid-on g  w (+ ox 1)  oy))
  (set g (grid-on g  w ox        (+ oy 1)))
  (set g (grid-on g  w (+ ox 1)  (+ oy 1)))
  g)

;; Toad — period-2 oscillator:
;;   .###
;;   ###.
(defn place-toad (grid w ox oy)
  (let g (grid-on grid w (+ ox 1) oy))
  (set g (grid-on g  w (+ ox 2)  oy))
  (set g (grid-on g  w (+ ox 3)  oy))
  (set g (grid-on g  w ox        (+ oy 1)))
  (set g (grid-on g  w (+ ox 1)  (+ oy 1)))
  (set g (grid-on g  w (+ ox 2)  (+ oy 1)))
  g)

;; -----------------------------------------------------------------------
;; Main — build the initial board, then run GENS generations
;; -----------------------------------------------------------------------

(let board (make-grid W H))
(set board (place-glider board W 1  1))
(set board (place-glider board W 14 1))
(set board (place-blinker board W 21 6))
(set board (place-block   board W 26 2))
(set board (place-toad    board W 11 11))

(display-grid board W 0)
(let gen 1)
(while (<= gen GENS)
  (set board (step board W H))
  (display-grid board W gen)
  (set gen (+ gen 1)))
