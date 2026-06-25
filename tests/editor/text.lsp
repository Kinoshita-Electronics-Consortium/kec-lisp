;; KEC Lisp editor tier — text-buffer conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).
;; The text buffer is Core-only; it does not depend on the zipper.

(load "editor/32-text.lsp")

(defn mk (s) (text-open "t" s))

(deftest "text/open-roundtrip-empty"
  (let b (mk ""))
  (check (= (text->string b) ""))
  (check (= (text-line-count b) 1))
  (check (not (text-modified? b))))

(deftest "text/open-roundtrip-multiline"
  (let b (mk "ab\ncd\nef"))
  (check (= (text->string b) "ab\ncd\nef"))
  (check (= (text-line-count b) 3)))

(deftest "text/self-insert"
  (let b (mk ""))
  (text-insert! b "h")
  (text-insert! b "i")
  (check (= (text->string b) "hi"))
  (check (= (text-point-col b) 2))
  (check (text-modified? b)))

(deftest "text/insert-mid-line"
  (let b (mk "ac"))
  (text-forward! b)                     ; col 1, between a and c
  (text-insert! b "b")
  (check (= (text->string b) "abc"))
  (check (= (text-point-col b) 2)))

(deftest "text/newline-splits"
  (let b (mk "abcd"))
  (text-forward! b) (text-forward! b)   ; col 2
  (text-newline! b)
  (check (= (text->string b) "ab\ncd"))
  (check (= (text-point-row b) 1))
  (check (= (text-point-col b) 0)))

(deftest "text/backspace-within-line"
  (let b (mk "abc"))
  (text-end! b)                         ; col 3
  (text-backspace! b)
  (check (= (text->string b) "ab"))
  (check (= (text-point-col b) 2)))

(deftest "text/backspace-at-bol-joins"
  (let b (mk "ab\ncd"))
  (text-next-line! b)                   ; on line "cd"
  (text-bol! b)
  (text-backspace! b)                   ; join -> "abcd"
  (check (= (text->string b) "abcd"))
  (check (= (text-point-row b) 0))
  (check (= (text-point-col b) 2)))

(deftest "text/backspace-at-buffer-start-noop"
  (let b (mk "abc"))
  (text-beg! b)
  (text-backspace! b)
  (check (= (text->string b) "abc")))

(deftest "text/delete-forward-joins"
  (let b (mk "ab\ncd"))
  (text-eol! b)                         ; end of line 0 (still on row 0)
  (text-delete! b)                      ; join next -> abcd
  (check (= (text->string b) "abcd")))

(deftest "text/vertical-move-clamps-col"
  (let b (mk "abcd\nxy"))
  (text-end! b)                         ; col 4 on line 0
  (text-next-line! b)                   ; "xy" len 2 -> col clamps to 2
  (check (= (text-point-col b) 2)))

(deftest "text/vertical-move-preserves-goal-column"
  ;; Emacs feel: C-n/C-p remember the DESIRED column. Passing through a short
  ;; line clamps the visible column but must NOT forget the goal — reaching a
  ;; long line again restores it. (Regression: the old clamp was destructive.)
  (let b (mk "abcd\nx\nyzwv"))          ; lens 4, 1, 4
  (text-eol! b)                         ; row0 end-of-line col4 -> goal 4
  (text-next-line! b)                   ; row1 "x" len1 -> col clamps to 1
  (check (= (text-point-col b) 1))
  (text-next-line! b)                   ; row2 "yzwv" -> col restores to goal 4
  (check (= (text-point-row b) 2))
  (check (= (text-point-col b) 4)))

(deftest "text/horizontal-move-resets-goal-column"
  ;; A horizontal move sets a new goal; a later vertical move honors it.
  (let b (mk "abcd\nx\nyzwv"))
  (text-eol! b)                         ; col4 goal4
  (text-next-line! b)                   ; "x" -> col1 (goal still 4)
  (text-backward! b)                    ; col0 -> goal reset to 0
  (text-next-line! b)                   ; "yzwv" -> col min(goal 0, 4) = 0
  (check (= (text-point-col b) 0)))

(deftest "text/forward-wraps-line"
  (let b (mk "ab\ncd"))
  (text-eol! b)                         ; col 2, end of "ab"
  (text-forward! b)                     ; wraps to start of "cd"
  (check (= (text-point-row b) 1))
  (check (= (text-point-col b) 0)))

(deftest "text/backward-wraps-line"
  (let b (mk "ab\ncd"))
  (text-next-line! b)                   ; on "cd"
  (text-bol! b)                         ; col 0
  (text-backward! b)                    ; wraps to end of "ab"
  (check (= (text-point-row b) 0))
  (check (= (text-point-col b) 2)))

(deftest "text/beg-and-end"
  (let b (mk "a\nb\nc"))
  (text-end! b)
  (check (= (text-point-row b) 2))
  (check (= (text-point-col b) 1))
  (text-beg! b)
  (check (= (text-point-row b) 0))
  (check (= (text-point-col b) 0)))

(deftest "text/screen-renders-content-and-cursor"
  (let b (mk "hello\nworld"))
  (let s (text-screen b 20 6 "ready"))
  (check (string-contains? s "hello"))
  (check (string-contains? s "world"))
  (check (string-contains? s "ready"))
  ;; ends with a cursor-park escape: ESC [ row ; col H
  (check (string-suffix? s "H")))

(deftest "text/insert-tab-soft-spaces"
  ;; TAB inserts spaces to the next tab stop (width 2), so the cursor column
  ;; stays in sync with the renderer (a literal \t would desync on the grid).
  (let b (mk ""))
  (text-insert-tab! b)                   ; col0 -> 2 spaces
  (check (= (text->string b) "  "))
  (check (= (text-point-col b) 2))
  (text-insert! b "x")                   ; "  x" col3
  (text-insert-tab! b)                   ; col3 -> 1 space to the next even stop
  (check (= (text->string b) "  x ")))

(deftest "text/screen-horizontal-scroll"
  ;; A line wider than the window scrolls horizontally so point stays visible and
  ;; the hardware cursor is parked on-screen (col <= cols), never off the edge.
  (let b (mk "0123456789ABCDEFGHIJ"))    ; 20 chars
  (text-eol! b)                          ; pcol 20, window 10 wide
  (let s (text-screen b 10 5 ""))
  (check (string-contains? s "GHIJ"))    ; the tail is shown (right-scrolled)
  (check (not (string-contains? s "01234")))   ; the head scrolled off
  (check (string-contains? s ";10H"))    ; cursor parked at col 10 (== cols), on-screen
  (check (not (string-contains? s ";21H"))))   ; NOT off the right edge (pcol+1)

(deftest "text/mark-saved-clears-modified"
  (let b (mk "abc"))
  (text-insert! b "x")                   ; now dirty
  (check (text-modified? b))
  (text-mark-saved! b)                   ; a successful save clears the dirty flag
  (check (not (text-modified? b)))
  (check (= (text->string b) "xabc")))   ; content is untouched
