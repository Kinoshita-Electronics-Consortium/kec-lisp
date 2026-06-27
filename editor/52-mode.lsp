;; KEC Lisp editor tier — mode : general MAJOR MODES (the application-engine bundle).
;;
;; Part of the editor/REPL tier (ADR-0002), promoted toward the application engine
;; (kn-86 ADR-0046). Where 50-keymap is the keymap ENGINE, a MAJOR MODE bundles a
;; keymap with the rest of a mode's class-level identity: a render function
;; (st -> view-model), a setup function (() -> st | st -> st producing the initial
;; state), and an optional PARENT mode for keymap inheritance. A mode is a *class*,
;; not an instance — mode-local STATE is deliberately out of scope here (it is the
;; host's concern, extracted per ADR-0046 Decision 4 when the first program needs
;; it). Handlers keep the existing (handler st) -> st contract, so a mode's keymap
;; plugs straight into 50-keymap's *keymaps* registry and `mode-dispatch`.
;;
;; Inheritance is keymap-only: `major-mode-handler` resolves a token by checking
;; the mode's own keymap, then walking the :parent chain (child overrides parent),
;; with a bounded walk so a malformed parent cycle terminates instead of looping
;; (device GC stack is 256). Everything is pure lookup + call — headlessly
;; evaluable under `kec test`, no display dependency.
;;
;; record = vector [name keymap render setup parent]
;;
;; Load order: after 50-keymap (it reuses make-keymap / register-keymap /
;; keymap-handler / keymap-dispatch), before 55-bindings.

;; ----- the major-mode registry: name -> record --------------------------
(define *major-modes* (make-hash-table))

;; A bounded ceiling on the parent walk — also the cycle guard. Far above any
;; realistic mode-inheritance depth on a 34-key device.
(define MAJOR-MODE-MAX-DEPTH 32)

;; ----- flat-plist accessor ----------------------------------------------
;; opts is a flat plist (:key val :key val ...), distinct from 25-alist's `get`
;; (which keys an ALIST of pairs). Iterative — walks key/value pairs, returns the
;; value for `key` or nil. (Core ships only the alist `get` + the symbol-property
;; `get-prop`; a tiny flat-plist reader is the missing piece this module needs.)
(defn %plist-get (key plist)
  (let cur plist)
  (let found nil)
  (let done nil)
  (while (and (not done) (pair? cur) (pair? (cdr cur)))
    (if (is (car cur) key)
        (do (set found (car (cdr cur))) (set done t))
        (set cur (cdr (cdr cur)))))
  found)

;; ----- construction -----------------------------------------------------
;; (define-major-mode name opts) — opts is a plist:
;;   (:keymap km :render render-fn :setup setup-fn :parent parent-name)
;; All optional. A keymap is auto-created when not supplied. Stores the record in
;; *major-modes* AND registers the keymap in 50-keymap's *keymaps* so the existing
;; `mode-dispatch` keeps working. Returns name.
(defn define-major-mode (name opts)
  (let km     (or (%plist-get ':keymap opts) (make-keymap)))
  (let render (%plist-get ':render opts))
  (let setup  (%plist-get ':setup opts))
  (let parent (%plist-get ':parent opts))
  (let rec (vector name km render setup parent))
  (hash-set! *major-modes* name rec)
  (register-keymap name km)
  name)

;; ----- accessors --------------------------------------------------------
(defn major-mode (name) (hash-ref *major-modes* name))
(defn major-mode? (name) (if (hash-has? *major-modes* name) t nil))
(defn major-mode-list () (hash-keys *major-modes*))

(defn %major-mode-field (name i)
  (let rec (hash-ref *major-modes* name))
  (if (nil? rec) nil (vector-ref rec i)))

(defn major-mode-keymap (name) (%major-mode-field name 1))
(defn major-mode-render (name) (%major-mode-field name 2))
(defn major-mode-setup  (name) (%major-mode-field name 3))
(defn major-mode-parent (name) (%major-mode-field name 4))

;; ----- keymap inheritance -----------------------------------------------
;; (major-mode-handler name token event-type) -> the resolved handler, or nil.
;; Checks name's keymap first, then walks the :parent chain (child overrides
;; parent). Bounded to MAJOR-MODE-MAX-DEPTH steps so a parent cycle terminates.
(defn major-mode-handler (name token event-type)
  (let cur name)
  (let h nil)
  (let depth 0)
  (while (and (nil? h) (not (nil? cur)) (< depth MAJOR-MODE-MAX-DEPTH))
    (let km (major-mode-keymap cur))
    (if (nil? km) nil (set h (keymap-handler km token event-type)))
    (set cur (major-mode-parent cur))
    (set depth (+ depth 1)))
  h)

;; (major-mode-dispatch name token event-type st) -> next state.
;; Like 50-keymap's mode-dispatch but inheritance-aware (uses major-mode-handler).
;; Unbound token / unknown mode is a no-op: returns st as-is.
(defn major-mode-dispatch (name token event-type st)
  (let h (major-mode-handler name token event-type))
  (if (nil? h) st (h st)))

;; ----- lifecycle: enter -------------------------------------------------
;; (major-mode-enter name st) -> the state after running the mode's setup.
;; nil setup (or unknown mode) returns st unchanged. setup is applied to `st`, so
;; both setup forms work under Fe's arity tolerance: a (() -> st) initial-state
;; function ignores the argument, an (st -> st) function consumes it.
(defn major-mode-enter (name st)
  (let setup (major-mode-setup name))
  (if (nil? setup) st (setup st)))

(provide 'editor/mode)
