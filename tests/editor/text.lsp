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

(deftest "text/screen-eob-rows-blank-not-tilde"
  ;; Emacs leaves rows past end-of-buffer blank; the ~ fringe marker is vim's
  ;; signature and knEmacs copies Emacs, never vim.
  (let b (mk "hello"))
  (let s (text-screen b 20 8 "ok"))
  (check (string-contains? s "hello"))
  (check (not (string-contains? s "~"))))

;; ---- search ----------------------------------------------------------------
(deftest "text/search-forward-finds"
  (let b (mk "hello world\nfoo hello"))
  (let m (text-search-forward b "hello" 0 0))
  (check (= (car m) 0)) (check (= (cdr m) 0))          ; first match at (0,0)
  (let m2 (text-search-forward b "hello" 0 1))         ; from (0,1) -> (1,4)
  (check (= (car m2) 1)) (check (= (cdr m2) 4)))

(deftest "text/search-forward-miss"
  (let b (mk "abc"))
  (check (nil? (text-search-forward b "xyz" 0 0))))

(deftest "text/search-move-sets-point-and-mark"
  (let b (mk "abc hello xyz"))
  (check (text-search-move! b "hello" 0 0))
  (check (= (text-point-col b) 9))                     ; point at end of match (4+5)
  (let mm (text-mark b))
  (check (= (car mm) 0)) (check (= (cdr mm) 4)))       ; mark at start of match

(deftest "text/search-move-miss-keeps-point"
  (let b (mk "abc"))
  (text-eol! b)                                        ; col 3
  (check (nil? (text-search-move! b "z" 0 0)))
  (check (= (text-point-col b) 3)))

(deftest "text/search-empty-needle-noop"
  (let b (mk "abc"))
  (check (nil? (text-search-move! b "" 0 0))))

;; ---- mark / region / kill / yank -------------------------------------------
(deftest "text/mark-and-kill-region"
  (let b (mk "hello world"))
  (text-set-mark! b)                     ; mark (0,0)
  (text-eol! b)                          ; point (0,11)
  (text-kill-region! b)
  (check (= (text->string b) ""))
  (check (= (text-point-col b) 0))
  (text-yank! b)                         ; paste back
  (check (= (text->string b) "hello world")))

(deftest "text/kill-ring-save-keeps-text"
  (let b (mk "abc"))
  (text-set-mark! b)
  (text-eol! b)
  (text-kill-ring-save! b)               ; copy, no delete
  (check (= (text->string b) "abc"))
  (text-eol! b)
  (text-yank! b)
  (check (= (text->string b) "abcabc")))

(deftest "text/kill-region-multiline"
  (let b (mk "ab\ncd\nef"))
  (text-set-mark! b)                     ; (0,0)
  (text-next-line! b)                    ; (1,0); region = "ab\n"
  (text-kill-region! b)
  (check (= (text->string b) "cd\nef"))
  (text-yank! b)
  (check (= (text->string b) "ab\ncd\nef")))

(deftest "text/kill-region-reversed-order"
  (let b (mk "hello"))
  (text-eol! b)                          ; point (0,5)
  (text-set-mark! b)                     ; mark (0,5)
  (text-beg! b)                          ; point (0,0); region 0..5
  (text-kill-region! b)
  (check (= (text->string b) "")))

(deftest "text/kill-line"
  (let b (mk "hello world"))
  (text-eol! b) (text-bol! b)            ; col0
  (text-forward! b) (text-forward! b) (text-forward! b) (text-forward! b) (text-forward! b) ; col5
  (text-kill-line! b)                    ; kill " world"
  (check (= (text->string b) "hello"))
  (text-yank! b)
  (check (= (text->string b) "hello world")))

(deftest "text/kill-line-at-eol-joins"
  (let b (mk "ab\ncd"))
  (text-eol! b)                          ; (0,2)
  (text-kill-line! b)                    ; kills the newline
  (check (= (text->string b) "abcd")))

(deftest "text/kill-region-undo"
  (let b (mk "hello"))
  (text-set-mark! b) (text-eol! b)
  (text-kill-region! b)
  (check (= (text->string b) ""))
  (text-undo! b)
  (check (= (text->string b) "hello")))

(deftest "text/yank-empty-ring-noop"
  (let b (mk "x"))
  (text-yank! b)
  (check (= (text->string b) "x")))

;; ---- undo / redo (command-based) -------------------------------------------
(deftest "text/undo-insert"
  (let b (mk "abc"))
  (text-insert! b "X")                   ; "Xabc"
  (check (= (text->string b) "Xabc"))
  (text-undo! b)
  (check (= (text->string b) "abc")))

(deftest "text/undo-coalesces-typing"
  (let b (mk ""))
  (text-insert! b "h") (text-insert! b "i") (text-insert! b "!")
  (check (= (text->string b) "hi!"))
  (text-undo! b)                         ; one undo removes the whole contiguous run
  (check (= (text->string b) "")))

(deftest "text/undo-newline"
  (let b (mk "abcd"))
  (text-forward! b) (text-forward! b)    ; col 2
  (text-newline! b)                      ; "ab\ncd"
  (check (= (text->string b) "ab\ncd"))
  (text-undo! b)                         ; rejoin
  (check (= (text->string b) "abcd")))

(deftest "text/undo-backspace"
  (let b (mk "abc"))
  (text-eol! b)                          ; col 3
  (text-backspace! b)                    ; "ab"
  (check (= (text->string b) "ab"))
  (text-undo! b)                         ; restore the deleted char
  (check (= (text->string b) "abc")))

(deftest "text/undo-delete-forward"
  (let b (mk "abc"))                     ; col 0
  (text-delete! b)                       ; "bc"
  (check (= (text->string b) "bc"))
  (text-undo! b)
  (check (= (text->string b) "abc")))

(deftest "text/undo-backspace-join-resplits"
  (let b (mk "ab\ncd"))
  (text-next-line! b) (text-bol! b)      ; row1 col0
  (text-backspace! b)                    ; join -> "abcd"
  (check (= (text->string b) "abcd"))
  (text-undo! b)                         ; must re-split
  (check (= (text->string b) "ab\ncd")))

(deftest "text/redo"
  (let b (mk ""))
  (text-insert! b "x")
  (text-undo! b)
  (check (= (text->string b) ""))
  (text-redo! b)
  (check (= (text->string b) "x")))

(deftest "text/edit-clears-redo"
  (let b (mk ""))
  (text-insert! b "x") (text-undo! b)    ; redo now has the insert
  (text-insert! b "y")                   ; a fresh edit clears redo
  (text-redo! b)                         ; no-op
  (check (= (text->string b) "y")))

(deftest "text/undo-empty-is-noop"
  (let b (mk "abc"))
  (check (not (text-can-undo? b)))
  (text-undo! b)
  (check (= (text->string b) "abc")))

(deftest "text/mark-saved-clears-modified"
  (let b (mk "abc"))
  (text-insert! b "x")                   ; now dirty
  (check (text-modified? b))
  (text-mark-saved! b)                   ; a successful save clears the dirty flag
  (check (not (text-modified? b)))
  (check (= (text->string b) "xabc")))   ; content is untouched
