;; KEC Lisp editor tier — keymap engine conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/50-keymap.lsp")

(defn mkbuf (name s) (make-buffer name (read-all s)))

(deftest "keymap/define-and-get"
  (let km (make-keymap))
  (check (nil? (keymap-get km 'FOO)))
  (define-key km 'FOO (fn (st) (+ st 1)))
  (check (not (nil? (keymap-get km 'FOO)))))

(deftest "keymap/dispatch-tap"
  (let km (make-keymap))
  (define-key km 'INC (fn (st) (+ st 1)))
  (check (is (keymap-dispatch km 'INC ':tap 10) 11)))

(deftest "keymap/unbound-is-noop"
  (let km (make-keymap))
  (check (is (keymap-dispatch km 'NOPE ':tap 7) 7)))    ; state unchanged

(deftest "keymap/three-slots-and-fallback"
  (let km (make-keymap))
  (define-key km 'K (fn (st) (cons 'tap st)))
  (define-key km 'K ':double-tap (fn (st) (cons 'double st)))
  ;; :tap -> tap handler
  (check (is (car (keymap-dispatch km 'K ':tap nil)) 'tap))
  ;; :double-tap -> its own handler
  (check (is (car (keymap-dispatch km 'K ':double-tap nil)) 'double))
  ;; :long-press -> falls back to :tap (no long-press bound)
  (check (is (car (keymap-dispatch km 'K ':long-press nil)) 'tap)))

(deftest "keymap/keymap-handler-resolution"
  (let km (make-keymap))
  (define-key km 'X ':long-press (fn (st) st))
  (check (nil? (keymap-handler km 'X ':tap)))           ; no :tap, no fallback target
  (check (not (nil? (keymap-handler km 'X ':long-press)))))

(deftest "keymap/rebind-hook-fires"
  (let fired nil)
  (set *keymap-rebind-hook* (fn (km token) (set fired token)))
  (let km (make-keymap))
  (define-key km 'BIND-ME (fn (st) st))
  (check (is fired 'BIND-ME))
  (set *keymap-rebind-hook* nil))                        ; reset

(deftest "keymap/copy-is-independent"
  (let km (make-keymap))
  (define-key km 'A (fn (st) 'orig))
  (let km2 (copy-keymap km))
  (define-key km2 'A (fn (st) 'changed))
  (check (is (keymap-dispatch km 'A ':tap nil) 'orig))   ; original untouched
  (check (is (keymap-dispatch km2 'A ':tap nil) 'changed)))

(deftest "keymap/mode-registry"
  (check (not (nil? (keymap-mode MODE-NEMACS-NAV))))     ; default registered
  (let n (length (keymap-mode-list)))
  (register-keymap ':test-mode (make-keymap))
  (check (is (length (keymap-mode-list)) (+ n 1)))
  (check (not (nil? (keymap-mode ':test-mode)))))

;; ---- the default :nemacs-nav grammar drives the buffer (integration) ----
(deftest "keymap/nemacs-nav-navigation"
  (let b (mkbuf "s" "(a b c)"))
  (mode-dispatch MODE-NEMACS-NAV 'CAR ':tap b)          ; descend -> a
  (check (is (buffer-focus b) 'a))
  (mode-dispatch MODE-NEMACS-NAV 'CDR ':tap b)          ; next -> b
  (check (is (buffer-focus b) 'b))
  (mode-dispatch MODE-NEMACS-NAV 'QUOTE ':tap b)        ; prev -> a
  (check (is (buffer-focus b) 'a))
  (mode-dispatch MODE-NEMACS-NAV 'BACK ':tap b)         ; ascend -> (a b c)
  (check (equal? (buffer-focus b) (read-string "(a b c)"))))

(deftest "keymap/nemacs-nav-edits"
  (let b (mkbuf "s" "(a b c)"))
  (mode-dispatch MODE-NEMACS-NAV 'CAR ':tap b)          ; on a
  (mode-dispatch MODE-NEMACS-NAV 'CONS ':tap b)         ; wrap a -> (a)
  (check (equal? (buffer-forms b) (read-all "((a) b c)")))
  (check (buffer-modified? b))
  ;; CDR long-press deletes; double-tap falls back to :tap (next)
  (let b2 (mkbuf "s" "(a b c)"))
  (mode-dispatch MODE-NEMACS-NAV 'CAR ':tap b2)         ; on a
  (mode-dispatch MODE-NEMACS-NAV 'CDR ':long-press b2)  ; delete a -> (b c)
  (check (equal? (buffer-forms b2) (read-all "(b c)"))))

;; ---- boundary moves propagate (SEAM S7); the host wraps dispatch ----
(deftest "keymap/boundary-raises-for-host"
  (let b (mkbuf "s" "(a b)"))
  (mode-dispatch MODE-NEMACS-NAV 'CAR ':tap b)          ; on a (a leaf)
  (check-err (mode-dispatch MODE-NEMACS-NAV 'CAR ':tap b)))  ; descend into leaf -> raise
