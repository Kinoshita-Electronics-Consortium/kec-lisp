;; KEC Lisp editor tier — text : a real TEXT buffer for knEmacs.
;;
;; Part of the editor/REPL tier (ADR-0002), loaded on demand by a host (the
;; `kec` CLI nemacs surface, or the KN-86 firmware). The lesson from rxi/lite and
;; Emacs: the buffer IS text — lines of characters with a point — and structure
;; (paren-matching, sexp motion) is a lens computed ON TOP, never the
;; representation. This module is that text buffer. The structural zipper
;; (10-zipper / 30-buffer) is NOT replaced — it still backs the `kec repl`
;; structural prompt, and returns later as the engine behind a structural
;; command (the lite "structure-as-a-lens" pattern). See the plan / ADR-0046.
;;
;; Representation: a LINE ZIPPER (the classic editor structure, no list indexing)
;;   record = vector [above cur below col name modified? scroll]
;;     above  : reversed list of the lines ABOVE the cursor line
;;     cur    : the current line (a string)
;;     below  : the lines BELOW the cursor line, in order
;;     col    : column within cur (0 .. (string-length cur))
;;     name   : buffer name (e.g. a file path or "*scratch*")
;;     modified? : nil, or t once an edit has happened
;;     scroll : top visible line index (owned by the renderer; see 32 Step 2)
;;   point-row is implicit = (length above).
;;
;; Every keystroke touches only `cur` (a substring/string-append splice) or
;; shuffles ONE line between above/below. All O(1); all iterative (KEC GC-stack
;; discipline). Built on Core only (10-list, 60-str, 52-container) — no zipper.
;;
;; Load order: anywhere after Core; independent of 10-zipper / 30-buffer.

;; ---- line splitting (on byte 10 = newline) ---------------------------------
;; Always returns at least one line. "" -> ("") ; "a\nb" -> ("a" "b") ;
;; "a\n" -> ("a" "") ; "\n" -> ("" ""). One O(n) pass via the host `string-split`
;; primitive — the old per-index `(string-ref s i)` loop was O(n^2) (string-ref
;; restringifies the whole object each call), so opening a large file hung for
;; tens of seconds.
(defn %split-lines (s) (string-split s 10))

;; ---- constructor ------------------------------------------------------------
;; (text-open name content) — a text buffer named `name` holding `content`.
;; Cursor seated at the top-left (row 0, col 0); not modified.
(defn text-open (name content)
  (let lines (%split-lines content))
  (vector nil (car lines) (cdr lines) 0 name nil 0))

;; ---- accessors --------------------------------------------------------------
(defn text-above (b)     (vector-ref b 0))
(defn text-cur (b)       (vector-ref b 1))
(defn text-below (b)     (vector-ref b 2))
(defn text-col (b)       (vector-ref b 3))
(defn text-name (b)      (vector-ref b 4))
(defn text-modified? (b) (vector-ref b 5))
(defn text-scroll (b)    (vector-ref b 6))

(defn text-point-col (b) (text-col b))
(defn text-point-row (b) (length (text-above b)))
(defn text-line-count (b)
  (+ (length (text-above b)) 1 (length (text-below b))))

;; ---- internal helpers -------------------------------------------------------
(defn %text-set-col! (b c) (vector-set! b 3 c) b)
(defn %text-mark! (b) (vector-set! b 5 t) b)
;; (text-mark-saved! b) — clear the dirty flag after a successful save, so the
;; modeline drops its "*" and the host's quit guard knows there is nothing to
;; lose. The host calls this once `write-file` has succeeded; content is untouched.
(defn text-mark-saved! (b) (vector-set! b 5 nil) b)
;; clamp col into [0, len cur] (after a vertical move onto a shorter line)
(defn %text-clamp-col! (b)
  (let n (string-length (text-cur b)))
  (if (< n (text-col b)) (vector-set! b 3 n))
  b)

;; ---- serialize --------------------------------------------------------------
;; (text->string b) — the whole buffer as text, lines joined by newline.
(defn text->string (b)
  (join (append (reverse (text-above b)) (cons (text-cur b) (text-below b)))
        (char->string 10)))

;; ============================================================================
;; MOTION — cursor only, never marks modified.
;; ============================================================================

;; line down: shuffle cur up into `above`, pull the first `below` line into cur.
(defn text-next-line! (b)
  (if (text-below b)
      (do
        (vector-set! b 0 (cons (text-cur b) (text-above b)))
        (vector-set! b 1 (car (text-below b)))
        (vector-set! b 2 (cdr (text-below b)))
        (%text-clamp-col! b))
      b))

;; line up: mirror of text-next-line!.
(defn text-prev-line! (b)
  (if (text-above b)
      (do
        (vector-set! b 2 (cons (text-cur b) (text-below b)))
        (vector-set! b 1 (car (text-above b)))
        (vector-set! b 0 (cdr (text-above b)))
        (%text-clamp-col! b))
      b))

;; forward char: col+1, wrapping to the start of the next line at end-of-line.
(defn text-forward! (b)
  (let c (text-col b))
  (if (< c (string-length (text-cur b)))
      (%text-set-col! b (+ c 1))
      (if (text-below b)
          (do (text-next-line! b) (%text-set-col! b 0))
          b)))

;; backward char: col-1, wrapping to the end of the previous line at col 0.
(defn text-backward! (b)
  (let c (text-col b))
  (if (< 0 c)
      (%text-set-col! b (- c 1))
      (if (text-above b)
          (do (text-prev-line! b)
              (%text-set-col! b (string-length (text-cur b))))
          b)))

(defn text-bol! (b) (%text-set-col! b 0))
(defn text-eol! (b) (%text-set-col! b (string-length (text-cur b))))

;; beginning / end of buffer.
(defn text-beg! (b)
  (while (text-above b) (text-prev-line! b))
  (text-bol! b))
(defn text-end! (b)
  (while (text-below b) (text-next-line! b))
  (text-eol! b))

;; ============================================================================
;; EDITING — splice `cur` or join/split lines; marks modified.
;; ============================================================================

;; (text-insert! b s) — insert string s (usually one char) at point; advance col.
(defn text-insert! (b s)
  (let cur (text-cur b))
  (let c (text-col b))
  (let left (substring cur 0 c))
  (let right (substring cur c (string-length cur)))
  (vector-set! b 1 (string-append left s right))
  (vector-set! b 3 (+ c (string-length s)))
  (%text-mark! b))

;; (text-newline! b) — split cur at point; the left half becomes a finished line
;; above, the right half becomes the new cur; col -> 0.
(defn text-newline! (b)
  (let cur (text-cur b))
  (let c (text-col b))
  (let left (substring cur 0 c))
  (let right (substring cur c (string-length cur)))
  (vector-set! b 0 (cons left (text-above b)))
  (vector-set! b 1 right)
  (vector-set! b 3 0)
  (%text-mark! b))

;; (text-backspace! b) — delete the char before point; at col 0, join with the
;; previous line (cursor lands at the seam). No-op at the very start of buffer.
(defn text-backspace! (b)
  (let cur (text-cur b))
  (let c (text-col b))
  (if (< 0 c)
      (do
        (let left (substring cur 0 (- c 1)))
        (let right (substring cur c (string-length cur)))
        (vector-set! b 1 (string-append left right))
        (vector-set! b 3 (- c 1))
        (%text-mark! b))
      (if (text-above b)
          (do
            (let prev (car (text-above b)))
            (vector-set! b 0 (cdr (text-above b)))
            (vector-set! b 3 (string-length prev))
            (vector-set! b 1 (string-append prev cur))
            (%text-mark! b))
          b)))

;; (text-delete! b) — delete the char at point (forward); at end-of-line, join
;; the next line up. No-op at the very end of buffer.
(defn text-delete! (b)
  (let cur (text-cur b))
  (let c (text-col b))
  (let n (string-length cur))
  (if (< c n)
      (do
        (let left (substring cur 0 c))
        (let right (substring cur (+ c 1) n))
        (vector-set! b 1 (string-append left right))
        (%text-mark! b))
      (if (text-below b)
          (do
            (let nxt (car (text-below b)))
            (vector-set! b 2 (cdr (text-below b)))
            (vector-set! b 1 (string-append cur nxt))
            (%text-mark! b))
          b)))

;; ============================================================================
;; RENDER — paint the buffer for a (cols x rows) terminal, ANSI.
;; Layout: row 1 = modeline (inverse bar), rows 2..rows-1 = text window
;; (vertical-scrolled so point stays visible), row `rows` = status/echo line.
;; The returned string ENDS with an absolute cursor-park escape so the
;; terminal's own cursor sits at point. The host clears the screen each frame.
;; ============================================================================

(defn %esc () (char->string 27))
(defn %cursor-to (r c) (str (%esc) "[" (number->string r) ";" (number->string c) "H"))
;; clip a string to its first w bytes (substring clamps when w >= length)
(defn %clip (s w) (substring s 0 w))

(defn text-screen (b cols rows status)
  (let content-rows (if (< rows 3) 1 (- rows 2)))
  (let prow (text-point-row b))
  (let pcol (text-point-col b))
  ;; recompute vertical scroll so point is on-screen, persist it
  (let scroll (text-scroll b))
  (if (< prow scroll) (set scroll prow))
  (if (<= (+ scroll content-rows) prow) (set scroll (+ (- prow content-rows) 1)))
  (if (< scroll 0) (set scroll 0))
  (vector-set! b 6 scroll)
  ;; all lines, flat; take just the visible window
  (let lines (append (reverse (text-above b)) (cons (text-cur b) (text-below b))))
  (let win (take (drop lines scroll) content-rows))
  (let win-n (length win))
  ;; modeline: inverse bar, name + modified marker + L/C indicator
  (let ml (str " " (text-name b) (if (text-modified? b) " * " "   ")
               " L" (number->string (+ prow 1)) " C" (number->string (+ pcol 1))))
  (let out (str (%esc) "[7m" (pad-right (%clip ml cols) cols) (%esc) "[0m"))
  ;; content rows (blank rows past end-of-buffer get a ~ marker, vi-style)
  (let i 0)
  (while (< i content-rows)
    (set out (str out (char->string 10)
                  (if (< i win-n) (%clip (nth win i) cols) "~")))
    (set i (+ i 1)))
  ;; status / echo line on the bottom row
  (set out (str out (char->string 10) (%clip status cols)))
  ;; park the hardware cursor at point (1-based; row 1 = modeline, body from 2)
  (str out (%cursor-to (+ (- prow scroll) 2) (+ pcol 1))))

(provide 'editor/text)
