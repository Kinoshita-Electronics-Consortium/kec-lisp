;; KEC Lisp editor tier — general major modes (52-mode) conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/50-keymap.lsp")
(load "editor/52-mode.lsp")

;; ----- define + accessors -----------------------------------------------
(deftest "mode/define-and-accessors"
  (let km (make-keymap))
  (define-key km 'CAR (fn (st) (cons 'car st)))
  (define-major-mode ':m-basic (list ':keymap km
                                     ':render (fn (st) (list ':vm st))
                                     ':setup  (fn () 'fresh)))
  (check (not (nil? (major-mode ':m-basic))))
  (check (is (major-mode-keymap ':m-basic) km))
  (check (not (nil? (major-mode-render ':m-basic))))
  (check (not (nil? (major-mode-setup ':m-basic))))
  (check (nil? (major-mode-parent ':m-basic)))
  ;; define-major-mode registers into *keymaps* so mode-dispatch still works
  (check (not (nil? (keymap-mode ':m-basic)))))

(deftest "mode/define-returns-name"
  (check (is (define-major-mode ':m-ret nil) ':m-ret)))

(deftest "mode/optional-opts-default-nil"
  (define-major-mode ':m-empty nil)
  (check (nil? (major-mode-render ':m-empty)))
  (check (nil? (major-mode-setup ':m-empty)))
  (check (nil? (major-mode-parent ':m-empty)))
  ;; a keymap is always present (auto-created when not supplied)
  (check (not (nil? (major-mode-keymap ':m-empty)))))

;; ----- major-mode? / major-mode-list ------------------------------------
(deftest "mode/predicate"
  (define-major-mode ':m-pred nil)
  (check (major-mode? ':m-pred))
  (check (nil? (major-mode? ':no-such-mode))))

(deftest "mode/list-includes-defined"
  (define-major-mode ':m-listed nil)
  (check (member ':m-listed (major-mode-list))))

;; ----- keymap inheritance: child overrides parent -----------------------
(deftest "mode/child-overrides-parent"
  (let pk (make-keymap))
  (define-key pk 'CAR (fn (st) (cons 'parent-car st)))
  (define-key pk 'CDR (fn (st) (cons 'parent-cdr st)))
  (define-major-mode ':m-parent (list ':keymap pk))
  (let ck (make-keymap))
  (define-key ck 'CAR (fn (st) (cons 'child-car st)))   ; override CAR only
  (define-major-mode ':m-child (list ':keymap ck ':parent ':m-parent))
  ;; child's own binding wins
  (check (is (car (major-mode-dispatch ':m-child 'CAR ':tap nil)) 'child-car))
  ;; child falls through to parent for CDR
  (check (is (car (major-mode-dispatch ':m-child 'CDR ':tap nil)) 'parent-cdr)))

(deftest "mode/handler-resolution-walks-chain"
  (let gk (make-keymap))
  (define-key gk 'BACK (fn (st) (cons 'grand-back st)))
  (define-major-mode ':m-grand (list ':keymap gk))
  (define-major-mode ':m-mid (list ':keymap (make-keymap) ':parent ':m-grand))
  (define-major-mode ':m-leaf (list ':keymap (make-keymap) ':parent ':m-mid))
  ;; resolves two parents up
  (check (not (nil? (major-mode-handler ':m-leaf 'BACK ':tap))))
  (check (is (car (major-mode-dispatch ':m-leaf 'BACK ':tap nil)) 'grand-back)))

;; ----- unbound everywhere = no-op ---------------------------------------
(deftest "mode/unbound-everywhere-is-noop"
  (define-major-mode ':m-noop-parent (list ':keymap (make-keymap)))
  (define-major-mode ':m-noop (list ':keymap (make-keymap) ':parent ':m-noop-parent))
  (check (nil? (major-mode-handler ':m-noop 'NOPE ':tap)))
  (check (is (major-mode-dispatch ':m-noop 'NOPE ':tap 99) 99)))   ; state unchanged

(deftest "mode/unknown-mode-dispatch-is-noop"
  (check (is (major-mode-dispatch ':no-such-mode 'CAR ':tap 7) 7))
  (check (nil? (major-mode-handler ':no-such-mode 'CAR ':tap))))

;; ----- enter: runs setup ------------------------------------------------
(deftest "mode/enter-runs-setup"
  (define-major-mode ':m-setup (list ':setup (fn () 'initial-state)))
  (check (is (major-mode-enter ':m-setup 'ignored) 'initial-state)))

(deftest "mode/enter-no-setup-returns-st"
  (define-major-mode ':m-no-setup nil)
  (check (is (major-mode-enter ':m-no-setup 'keep-me) 'keep-me)))

(deftest "mode/enter-unknown-mode-returns-st"
  (check (is (major-mode-enter ':no-such-mode 'untouched) 'untouched)))

;; ----- cycle guard: a parent cycle terminates ---------------------------
(deftest "mode/parent-cycle-terminates"
  (define-major-mode ':m-cyc-a (list ':keymap (make-keymap) ':parent ':m-cyc-b))
  (define-major-mode ':m-cyc-b (list ':keymap (make-keymap) ':parent ':m-cyc-a))
  ;; no binding anywhere + a cycle: the bounded walk returns nil rather than looping
  (check (nil? (major-mode-handler ':m-cyc-a 'NOPE ':tap)))
  (check (is (major-mode-dispatch ':m-cyc-a 'NOPE ':tap 5) 5)))
