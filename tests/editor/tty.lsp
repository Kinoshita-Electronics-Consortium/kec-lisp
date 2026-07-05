;; KEC Lisp editor tier — line view model + TTY painter conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/40-view.lsp")
(load "editor/96-tty.lsp")

(defn mkbuf (name s) (make-buffer name (read-all s)))

;; remove every occurrence of `seq` from s (iterative)
(defn %replace-seq (s seq)
  (let i (string-search s seq))
  (while i
    (set s (string-append (substring s 0 i)
                          (substring s (+ i (string-length seq)) (string-length s))))
    (set i (string-search s seq)))
  s)

;; strip the SGR sequences the painter inserts, so a width check sees only the
;; visible columns
(defn %tty-strip (s) (%replace-seq (%replace-seq s %REV) %RST))

(deftest "tty/view-lines-preorder"
  (let b (mkbuf "m" "(a (b c) d)"))
  (let lines (buffer->view-lines b))
  ;; root + form (a (b c) d) + a + (b c) + b + c + d  = 7 rows
  (check (is (length lines) 7))
  (check (is (view-line-depth (nth lines 0)) 0))   ; root at depth 0
  (check (= (view-line-label (nth lines 0)) "m"))  ; root = buffer name
  (check (is (view-line-depth (nth lines 1)) 1)))  ; top-level form deeper

(deftest "tty/view-lines-marks-cursor"
  (let b (mkbuf "s" "(a b c)"))
  (buffer-descend! b)                           ; focus a
  (buffer-next! b)                              ; focus b
  (let lines (buffer->view-lines b))
  (let cur (find view-line-cursor? lines))
  (check (not (nil? cur)))
  (check (= (view-line-label cur) "b"))         ; cursor line is b
  (check (is (count view-line-cursor? lines) 1))) ; exactly one cursor

(deftest "tty/view-lines-depth-increases"
  (let b (mkbuf "s" "(a (b (c)))"))
  (buffer-descend! b)                           ; a
  (buffer-next! b)                              ; (b (c))
  (buffer-descend! b)                           ; b
  (buffer-next! b)                              ; (c)
  (buffer-descend! b)                           ; c
  (let cur (find view-line-cursor? (buffer->view-lines b)))
  (check (= (view-line-label cur) "c"))
  (check (< 2 (view-line-depth cur))))          ; nested deep

(deftest "tty/screen-has-modeline-and-cursor"
  (let b (mkbuf "draft" "(a b c)"))
  (buffer-descend! b)
  (buffer-insert-leaf! b 'z)                     ; modified -> modeline shows *
  (let scr (tty-screen b 80 24))
  (check (string-contains? scr "draft *"))       ; modeline + modified marker
  (check (string-contains? scr %REV))            ; reverse-video used
  (check (string-contains? scr "\n")))           ; multi-line screen

(deftest "tty/help-advertises-only-bound-keys"
  ;; The help strip must list only keys that actually resolve through the
  ;; binding table (editor/55-bindings). C-M-f/b, C-M-d/u, C-M-k, M-(, and
  ;; "C-x C-e eval" were advertised but bound nowhere.
  (load "editor/32-text.lsp")
  (load "editor/55-bindings.lsp")
  (check (not (string-contains? %TTY-HELP "C-M-")))
  (check (not (string-contains? %TTY-HELP "M-(")))
  (check (not (string-contains? %TTY-HELP "C-x C-e")))
  ;; what it does advertise really is bound
  (check (not (nil? (key-command "C-/"))))
  (check (not (nil? (key-command "C-x C-s"))))
  (check (not (nil? (key-command "C-x C-c"))))
  (check (string-contains? %TTY-HELP "C-/ undo"))
  (check (string-contains? %TTY-HELP "C-x C-s save"))
  (check (string-contains? %TTY-HELP "C-x C-c exit")))

(deftest "tty/screen-scrolls-cursor-into-view"
  ;; 10 leaves under the root = 11 view lines; rows 6 -> 4 body rows. A cursor
  ;; past the visible window must scroll into view, not clip off-screen.
  (let b (mkbuf "s" "a b c d e f g h i j"))      ; cursor seated on a
  (let i 0)
  (while (< i 9) (buffer-next! b) (set i (+ i 1)))   ; focus j (view line 10)
  (let scr (tty-screen b 40 6))
  (check (string-contains? scr (string-append %REV "  j" %RST)))
  (check (< 0 (buffer-scroll b)))                ; scroll state persisted
  ;; moving back above the window scrolls up again
  (set i 0)
  (while (< i 9) (buffer-prev! b) (set i (+ i 1)))   ; focus a (view line 1)
  (let scr2 (tty-screen b 40 6))
  (check (string-contains? scr2 (string-append %REV "  a" %RST))))

(deftest "tty/screen-clips-to-width"
  (let b (mkbuf "n" "(a b)"))
  (let lines (split (tty-screen b 12 6) "\n"))
  (check (every? (fn (l) (<= (string-length (%tty-strip l)) 12)) lines)))
