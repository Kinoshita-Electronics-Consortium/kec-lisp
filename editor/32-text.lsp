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
;;   record = vector [above cur below col name modified? scroll goal hscroll
;;                     undo redo mark kill]
;;     above  : reversed list of the lines ABOVE the cursor line
;;     cur    : the current line (a string)
;;     below  : the lines BELOW the cursor line, in order
;;     col    : column within cur (0 .. (string-length cur))
;;     name   : buffer name (e.g. a file path or "*scratch*")
;;     modified? : nil, or t once an edit has happened
;;     scroll : top visible line index (owned by the renderer; see 32 Step 2)
;;     goal   : desired column for vertical motion — C-n/C-p aim here and clamp
;;              to shorter lines without forgetting it (Emacs goal-column feel)
;;     hscroll: leftmost visible column (owned by the renderer; long-line scroll)
;;     undo   : stack of inverse edit records (command-based undo; head = newest)
;;     redo   : stack of records undone, for redo (cleared by any fresh edit)
;;     mark   : (row . col) of the mark, or nil — the region is mark..point
;;     kill   : the kill ring (list of killed strings; head = most recent)
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
  ;; slots: above cur below col name modified? scroll goal hscroll undo redo mark kill
  (vector nil (car lines) (cdr lines) 0 name nil 0 0 0 nil nil nil nil))

;; ---- accessors --------------------------------------------------------------
(defn text-above (b)     (vector-ref b 0))
(defn text-cur (b)       (vector-ref b 1))
(defn text-below (b)     (vector-ref b 2))
(defn text-col (b)       (vector-ref b 3))
(defn text-name (b)      (vector-ref b 4))
(defn text-modified? (b) (vector-ref b 5))
(defn text-scroll (b)    (vector-ref b 6))
(defn text-goal (b)      (vector-ref b 7))
(defn text-hscroll (b)   (vector-ref b 8))

(defn text-point-col (b) (text-col b))
(defn text-point-row (b) (length (text-above b)))
(defn text-line-count (b)
  (+ (length (text-above b)) 1 (length (text-below b))))

;; ---- internal helpers -------------------------------------------------------
;; (%text-set-col! b c) — a HORIZONTAL move: set the column AND adopt it as the
;; goal column, so a subsequent vertical move aims to return here (Emacs feel).
(defn %text-set-col! (b c) (vector-set! b 3 c) (vector-set! b 7 c) b)
;; (%text-mark! b) — record an edit: mark dirty and reset the goal to the current
;; column (every edit re-anchors vertical motion to where the edit happened).
(defn %text-mark! (b) (vector-set! b 5 t) (vector-set! b 7 (text-col b)) b)
;; (text-mark-saved! b) — clear the dirty flag after a successful save, so the
;; modeline drops its "*" and the host's quit guard knows there is nothing to
;; lose. The host calls this once `write-file` has succeeded; content is untouched.
(defn text-mark-saved! (b) (vector-set! b 5 nil) b)
;; (%text-col-from-goal! b) — a VERTICAL move landed on a (possibly shorter) line:
;; seat the column at the goal clamped to the line length, WITHOUT changing the
;; goal — so passing through a short line and reaching a long one restores it.
(defn %text-col-from-goal! (b)
  (let n (string-length (text-cur b)))
  (let g (text-goal b))
  (vector-set! b 3 (if (< n g) n g))
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
        (%text-col-from-goal! b))
      b))

;; line up: mirror of text-next-line!.
(defn text-prev-line! (b)
  (if (text-above b)
      (do
        (vector-set! b 2 (cons (text-cur b) (text-below b)))
        (vector-set! b 1 (car (text-above b)))
        (vector-set! b 0 (cdr (text-above b)))
        (%text-col-from-goal! b))
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
;; EDITING
;;
;; Two layers. The %text-raw-* ops are the pure mutators: they splice `cur` or
;; join/split lines and mark the buffer dirty, but DO NOT touch undo. The public
;; text-* wrappers RECORD the inverse edit on the undo stack (slot 9) and clear
;; the redo stack (slot 10), then call the raw op. Undo/redo replay records via
;; the raw ops, so they never re-record. Undo is COMMAND-BASED (we store the
;; inverse operation, not a whole-buffer snapshot) so it stays cheap on a large
;; file — only the changed span is kept.
;;
;; An undo record is (op row col text): op is ':ins (insert `text` at row/col) or
;; ':del (delete `text`, which is currently at row/col). The two are inverses.
;; ============================================================================

;; ---- raw mutators (no undo) -------------------------------------------------
(defn %text-raw-insert! (b s)
  (let cur (text-cur b))
  (let c (text-col b))
  (vector-set! b 1 (string-append (substring cur 0 c) s (substring cur c (string-length cur))))
  (vector-set! b 3 (+ c (string-length s)))
  (%text-mark! b))

(defn %text-raw-newline! (b)
  (let cur (text-cur b))
  (let c (text-col b))
  (vector-set! b 0 (cons (substring cur 0 c) (text-above b)))
  (vector-set! b 1 (substring cur c (string-length cur)))
  (vector-set! b 3 0)
  (%text-mark! b))

(defn %text-raw-backspace! (b)
  (let cur (text-cur b))
  (let c (text-col b))
  (if (< 0 c)
      (do
        (vector-set! b 1 (string-append (substring cur 0 (- c 1)) (substring cur c (string-length cur))))
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

(defn %text-raw-delete! (b)
  (let cur (text-cur b))
  (let c (text-col b))
  (let n (string-length cur))
  (if (< c n)
      (do
        (vector-set! b 1 (string-append (substring cur 0 c) (substring cur (+ c 1) n)))
        (%text-mark! b))
      (if (text-below b)
          (do
            (let nxt (car (text-below b)))        ; capture BEFORE mutating below
            (vector-set! b 2 (cdr (text-below b)))
            (vector-set! b 1 (string-append cur nxt))
            (%text-mark! b))
          b)))

;; raw compound ops used by undo replay (and by yank): insert a string that may
;; contain newlines, and delete k forward "characters" (a line join counts as 1).
(defn %text-raw-insert-string! (b s)
  (let parts (%split-lines s))
  (%text-raw-insert! b (car parts))
  (set parts (cdr parts))
  (while parts
    (%text-raw-newline! b)
    (%text-raw-insert! b (car parts))
    (set parts (cdr parts)))
  b)

(defn %text-raw-delete-forward! (b k)
  (let i 0)
  (while (< i k) (%text-raw-delete! b) (set i (+ i 1)))
  b)

;; ---- undo / redo bookkeeping ------------------------------------------------
(define %text-undo-cap 512)            ; bounded history (device discipline)

;; push `rec` onto the undo stack (slot 9), bounded; clear redo (slot 10).
(defn %text-record! (b rec)
  (vector-set! b 9 (take (cons rec (vector-ref b 9)) %text-undo-cap))
  (vector-set! b 10 nil)
  b)

;; ---- recording edit commands (the bound verbs) ------------------------------
;; (text-insert! b s) — insert s (one line, no newline) at point. Consecutive
;; inserts that abut the previous run COALESCE into one undo step (typing a word
;; undoes at once).
(defn text-insert! (b s)
  (let r (text-point-row b))
  (let c (text-col b))
  (let stack (vector-ref b 9))
  (let top (if stack (car stack) nil))
  (if (and top (is (nth top 0) ':del) (is (nth top 1) r)
           (is (+ (nth top 2) (string-length (nth top 3))) c))
      (do                                ; extend the pending delete-span
        (vector-set! b 9 (cons (list ':del (nth top 1) (nth top 2)
                                     (string-append (nth top 3) s))
                               (cdr stack)))
        (vector-set! b 10 nil))
      (%text-record! b (list ':del r c s)))
  (%text-raw-insert! b s))

;; (text-newline! b) — split the line at point.
(defn text-newline! (b)
  (%text-record! b (list ':del (text-point-row b) (text-col b) (char->string 10)))
  (%text-raw-newline! b))

;; (text-backspace! b) — delete the char before point; at col 0 join the previous
;; line. No-op (and no undo record) at the very start of buffer.
(defn text-backspace! (b)
  (let r (text-point-row b))
  (let c (text-col b))
  (let cur (text-cur b))
  (if (< 0 c)
      (do (%text-record! b (list ':ins r (- c 1) (substring cur (- c 1) c)))
          (%text-raw-backspace! b))
      (if (text-above b)
          (do (%text-record! b (list ':ins (- r 1) (string-length (car (text-above b)))
                                     (char->string 10)))
              (%text-raw-backspace! b))
          b)))

;; (text-delete! b) — delete the char at point (forward); at end-of-line join the
;; next line. No-op (and no undo record) at the very end of buffer.
(defn text-delete! (b)
  (let r (text-point-row b))
  (let c (text-col b))
  (let cur (text-cur b))
  (let n (string-length cur))
  (if (< c n)
      (do (%text-record! b (list ':ins r c (substring cur c (+ c 1))))
          (%text-raw-delete! b))
      (if (text-below b)
          (do (%text-record! b (list ':ins r c (char->string 10)))
              (%text-raw-delete! b))
          b)))

;; (text-insert-tab! b) — TAB: insert spaces up to the next tab stop (width 2),
;; not a literal \t. A real tab renders as several cells on the fixed grid and
;; would desync the parked cursor (which counts one column per byte); soft spaces
;; keep point and the visible cursor in lockstep.
(define %text-tab-width 2)
(defn text-insert-tab! (b)
  (text-insert! b (pad-right "" (- %text-tab-width (mod (text-col b) %text-tab-width)))))

;; ---- jump to an absolute position (for undo replay) -------------------------
;; (text-goto! b row col) — move point to (row, col), clamping col to the line.
(defn text-goto! (b row col)
  (text-beg! b)
  (let r 0)
  (while (< r row) (text-next-line! b) (set r (+ r 1)))
  (let n (string-length (text-cur b)))
  (%text-set-col! b (if (< n col) n col)))

;; (%text-apply-record! b rec) — perform an undo record via the RAW ops and
;; return its inverse (for the opposite stack). Does not record.
(defn %text-apply-record! (b rec)
  (let op (nth rec 0)) (let row (nth rec 1)) (let col (nth rec 2)) (let txt (nth rec 3))
  (text-goto! b row col)
  (if (is op ':ins)
      (do (%text-raw-insert-string! b txt) (list ':del row col txt))
      (do (%text-raw-delete-forward! b (string-length txt)) (list ':ins row col txt))))

;; (text-undo! b) — undo the most recent edit; push its inverse onto redo.
(defn text-undo! (b)
  (let u (vector-ref b 9))
  (if (nil? u)
      b
      (do
        (vector-set! b 9 (cdr u))
        (vector-set! b 10 (cons (%text-apply-record! b (car u)) (vector-ref b 10)))
        b)))

;; (text-redo! b) — redo the most recently undone edit; push its inverse back
;; onto undo. (Replay uses raw ops, so the redo stack is NOT cleared.)
(defn text-redo! (b)
  (let rdo (vector-ref b 10))
  (if (nil? rdo)
      b
      (do
        (vector-set! b 10 (cdr rdo))
        (vector-set! b 9 (cons (%text-apply-record! b (car rdo)) (vector-ref b 9)))
        b)))

(defn text-can-undo? (b) (if (vector-ref b 9) t nil))
(defn text-can-redo? (b) (if (vector-ref b 10) t nil))

;; ============================================================================
;; MARK / REGION / KILL / YANK
;;
;; The mark (slot 11) is a (row . col) saved point; the region is the span between
;; mark and point (in either order). Killed text goes on the kill ring (slot 12,
;; bounded); yank inserts the most recent kill. Kills and yank are each ONE undo
;; step (a single inverse record), and route through the raw ops so they don't
;; re-record. Note: the mark is a plain position, not an adjusting marker — it is
;; not corrected if you edit above it before killing (use it set-then-kill).
;; ============================================================================

(define %text-kill-cap 60)

(defn text-mark (b) (vector-ref b 11))
;; (text-set-mark! b) — drop the mark at point (C-SPC).
(defn text-set-mark! (b)
  (vector-set! b 11 (cons (text-point-row b) (text-col b))) b)

(defn %text-kill-push! (b s)
  (vector-set! b 12 (take (cons s (vector-ref b 12)) %text-kill-cap)) b)

;; (row1,col1) <= (row2,col2) in document order?
(defn %text-pos-le? (r1 c1 r2 c2)
  (if (< r1 r2) t (if (< r2 r1) nil (<= c1 c2))))

;; the text of the span between ordered positions (sr,sc) <= (er,ec), with
;; embedded newlines for line breaks. Row indices are clamped defensively.
(defn %text-span-string (b sr sc er ec)
  (let lines (append (reverse (text-above b)) (cons (text-cur b) (text-below b))))
  (let nl (length lines))
  (if (>= sr nl) (set sr (- nl 1)))
  (if (>= er nl) (set er (- nl 1)))
  (if (< sr 0) (set sr 0))
  (if (< er 0) (set er 0))
  (if (is sr er)
      (substring (nth lines sr) sc ec)
      (do
        (let out (substring (nth lines sr) sc (string-length (nth lines sr))))
        (let i (+ sr 1))
        (while (< i er)
          (set out (str out (char->string 10) (nth lines i)))
          (set i (+ i 1)))
        (str out (char->string 10) (substring (nth lines er) 0 ec)))))

;; (%text-region b) -> (sr sc er ec text), mark/point ordered so (sr,sc) is first.
(defn %text-region (b)
  (let m (text-mark b))
  (let pr (text-point-row b)) (let pc (text-col b))
  (let mr (car m)) (let mc (cdr m))
  (let sr mr) (let sc mc) (let er pr) (let ec pc)
  (if (not (%text-pos-le? mr mc pr pc))
      (do (set sr pr) (set sc pc) (set er mr) (set ec mc)))
  (list sr sc er ec (%text-span-string b sr sc er ec)))

;; (text-kill-region! b) — C-w: kill the region (mark..point) to the ring and
;; delete it; point lands at the region start. No-op without a mark.
(defn text-kill-region! (b)
  (if (nil? (text-mark b))
      b
      (do
        (let rg (%text-region b))
        (let sr (nth rg 0)) (let sc (nth rg 1)) (let txt (nth rg 4))
        (%text-kill-push! b txt)
        (%text-record! b (list ':ins sr sc txt))   ; inverse of the delete
        (text-goto! b sr sc)
        (%text-raw-delete-forward! b (string-length txt))
        (vector-set! b 11 nil)                      ; deactivate the mark
        b)))

;; (text-kill-ring-save! b) — M-w: copy the region to the ring, no delete.
(defn text-kill-ring-save! (b)
  (if (nil? (text-mark b))
      b
      (do
        (%text-kill-push! b (nth (%text-region b) 4))
        (vector-set! b 11 nil)
        b)))

;; (text-kill-line! b) — C-k: kill from point to end of line (not the newline);
;; at end-of-line kill the newline (join the next line). No-op at buffer end.
(defn text-kill-line! (b)
  (let r (text-point-row b)) (let c (text-col b))
  (let cur (text-cur b)) (let n (string-length cur))
  (if (< c n)
      (do
        (let txt (substring cur c n))
        (%text-kill-push! b txt)
        (%text-record! b (list ':ins r c txt))
        (%text-raw-delete-forward! b (string-length txt))
        b)
      (if (text-below b)
          (do
            (%text-kill-push! b (char->string 10))
            (%text-record! b (list ':ins r c (char->string 10)))
            (%text-raw-delete! b)
            b)
          b)))

;; (text-yank! b) — C-y: insert the most recent kill at point; set the mark at the
;; start of the inserted text (Emacs leaves point after, mark before). One undo
;; step. No-op when the ring is empty.
(defn text-yank! (b)
  (let ring (vector-ref b 12))
  (if (nil? ring)
      b
      (do
        (let txt (car ring))
        (let r (text-point-row b)) (let c (text-col b))
        (%text-record! b (list ':del r c txt))     ; inverse of the insert
        (vector-set! b 11 (cons r c))              ; mark at start of yank
        (%text-raw-insert-string! b txt)
        b)))

;; ============================================================================
;; SEARCH — forward text search (drives the host's incremental C-s loop).
;; Single-line needles only (the isearch minibuffer can't contain a newline).
;; ============================================================================

;; (text-search-forward b needle sr sc) -> (row . col) of the first match at or
;; after (sr,sc), or nil. Iterates the line list (linear), not nth-per-line.
(defn text-search-forward (b needle sr sc)
  (let lines (append (reverse (text-above b)) (cons (text-cur b) (text-below b))))
  (let row 0)
  (while (< row sr) (set lines (cdr lines)) (set row (+ row 1)))
  (let result nil)
  (while (and (nil? result) lines)
    (let line (car lines))
    (let from (if (is row sr) sc 0))
    (let idx (string-search (substring line from (string-length line)) needle))
    (if idx (set result (cons row (+ from idx))))
    (set lines (cdr lines))
    (set row (+ row 1)))
  result)

;; (text-search-move! b needle fr fc) -> t if a match at/after (fr,fc) is found:
;; point moves to the match END and the mark is set at the match START (so the
;; hit is the region). nil and no movement on miss or an empty needle.
(defn text-search-move! (b needle fr fc)
  (if (is (string-length needle) 0)
      nil
      (do
        (let m (text-search-forward b needle fr fc))
        (if (nil? m)
            nil
            (do
              (vector-set! b 11 (cons (car m) (cdr m)))            ; mark at start
              (text-goto! b (car m) (+ (cdr m) (string-length needle)))  ; point at end
              t)))))

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
  ;; recompute horizontal scroll so point's column is on-screen, persist it. A
  ;; long line is shown from `hscroll`; the cursor parks within [1, cols] instead
  ;; of running off the right edge.
  (let hscroll (text-hscroll b))
  (if (< pcol hscroll) (set hscroll pcol))
  (if (>= pcol (+ hscroll cols)) (set hscroll (+ (- pcol cols) 1)))
  (if (< hscroll 0) (set hscroll 0))
  (vector-set! b 8 hscroll)
  ;; all lines, flat; take just the visible window
  (let lines (append (reverse (text-above b)) (cons (text-cur b) (text-below b))))
  (let win (take (drop lines scroll) content-rows))
  (let win-n (length win))
  ;; modeline: inverse bar, name + modified marker + L/C indicator (the C column
  ;; shows the true buffer column, 1-based — not the horizontally-scrolled one)
  (let ml (str " " (text-name b) (if (text-modified? b) " * " "   ")
               " L" (number->string (+ prow 1)) " C" (number->string (+ pcol 1))))
  (let out (str (%esc) "[7m" (pad-right (%clip ml cols) cols) (%esc) "[0m"))
  ;; content rows (blank rows past end-of-buffer get a ~ marker, vi-style); each
  ;; visible line is sliced from hscroll so the window pans across long lines
  (let i 0)
  (while (< i content-rows)
    (set out (str out (char->string 10)
                  (if (< i win-n)
                      (%clip (substring (nth win i) hscroll (+ hscroll cols)) cols)
                      "~")))
    (set i (+ i 1)))
  ;; status / echo line on the bottom row
  (set out (str out (char->string 10) (%clip status cols)))
  ;; park the hardware cursor at point (1-based; row 1 = modeline, body from 2;
  ;; column relative to hscroll so it stays inside the visible window)
  (str out (%cursor-to (+ (- prow scroll) 2) (+ (- pcol hscroll) 1))))

(provide 'editor/text)
