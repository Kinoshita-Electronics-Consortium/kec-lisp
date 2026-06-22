;; KEC Lisp editor tier — keymap : keymap-as-data + dispatch + mode scopes (L2/L3).
;;
;; Part of the editor/REPL tier (ADR-0002). A keymap maps abstract command
;; TOKENS (CAR, CDR, BACK, EVAL, ...) to handlers — never physical scancodes; a
;; host maps its keys to these tokens (SEAM S2). Dispatch is pure lookup + call,
;; so it is evaluable HEADLESSLY (no display dependency) — the whole module runs
;; under `kec test`.
;;
;; A keymap is a hash table (ADR-0003 containers): token -> entry, where an entry
;; is an alist of handler slots ((:tap . fn) (:double-tap . fn) (:long-press . fn)).
;; double-tap / long-press fall back to :tap when not separately bound. A handler
;; takes the editor state (a buffer) and returns the next state. Boundary moves
;; (a verb that `raise`s "invalid move") propagate to the host, which renders the
;; cue (SEAM S7) — dispatch does not swallow them.
;;
;; Modes (L3) are five logical scopes; the cursor position selects the active
;; mode (context-polymorphic) — the host calls dispatch with the resolved mode.
;;
;; Load order: after 30-buffer (the default :nemacs-nav keymap binds its verbs).

;; ----- mode scopes ------------------------------------------------------
(define MODE-NEMACS-NAV     ':nemacs-nav)
(define MODE-NEMACS-LITERAL ':nemacs-literal)
(define MODE-REPL-PROMPT    ':repl-prompt)
(define MODE-REPL-HISTORY   ':repl-history)
(define MODE-GRAB           ':grab)
(define KEYMAP-MODES (list MODE-NEMACS-NAV MODE-NEMACS-LITERAL
                           MODE-REPL-PROMPT MODE-REPL-HISTORY MODE-GRAB))

;; ----- optional rebind hook (D2 sets the policy; the library is neutral) -
;; Fired as (hook keymap token) after every define-key. nil = no hook.
(define *keymap-rebind-hook* nil)

;; ----- keymap construction ----------------------------------------------
(defn make-keymap () (make-hash-table))

;; (define-key km token handler)        -> bind token's :tap slot
;; (define-key km token slot handler)   -> bind a specific slot
;; Returns km. Fires *keymap-rebind-hook* if set.
(defn define-key (km token . rest)
  (let one (is (length rest) 1))
  (let slot (if one ':tap (car rest)))
  (let handler (if one (car rest) (car (cdr rest))))
  (hash-set! km token (put slot handler (hash-ref km token)))
  (when *keymap-rebind-hook* (*keymap-rebind-hook* km token))
  km)

;; (keymap-get km token) -> the entry (a slot alist), or nil if unbound.
(defn keymap-get (km token) (hash-ref km token))

;; (keymap-set km token entry) -> install a whole entry; returns km.
(defn keymap-set (km token entry) (hash-set! km token entry) km)

;; (keymap-handler km token event-type) -> the resolved handler, or nil.
;; event-type in (:tap :double-tap :long-press); non-:tap falls back to :tap.
(defn keymap-handler (km token event-type)
  (let entry (hash-ref km token))
  (if (nil? entry)
      nil
      (or (get event-type entry) (get ':tap entry))))

;; (copy-keymap km) -> a shallow copy (entries shared).
(defn copy-keymap (km) (alist->hash (hash->alist km)))

;; ----- dispatch ---------------------------------------------------------
;; (keymap-dispatch km token event-type st) -> next state.
;; Unbound token (or unfilled slot with no :tap) is a no-op: returns st as-is.
;; A bound handler is called as (handler st). Pure lookup + call — headless.
(defn keymap-dispatch (km token event-type st)
  (let h (keymap-handler km token event-type))
  (if (nil? h) st (h st)))

;; ----- mode registry (L3): mode-scope -> keymap -------------------------
(define *keymaps* (make-hash-table))

(defn register-keymap (mode km) (hash-set! *keymaps* mode km) km)
(defn keymap-mode (mode) (hash-ref *keymaps* mode))
(defn keymap-mode-list () (hash-keys *keymaps*))

;; (mode-dispatch mode token event-type st) -> next state, via the mode's keymap.
;; An unregistered mode is a no-op.
(defn mode-dispatch (mode token event-type st)
  (let km (keymap-mode mode))
  (if (nil? km) st (keymap-dispatch km token event-type st)))

;; ----- default :nemacs-nav keymap (the ADR-0008 structural grammar) -----
;; Robbed from the KN-86 nEmacs screen on-key: CAR descends, CDR moves to the
;; next sibling, BACK ascends. CONS (open completion), ENT (accept), and EVAL
;; (evaluate) are bound by the ranker / REPL workstreams onto this same mutable
;; keymap once those verbs exist. Additional structural edits are bound here so
;; the editor is usable standalone.
(define *nemacs-nav-keymap* (make-keymap))
(define-key *nemacs-nav-keymap* 'CAR   (fn (st) (buffer-descend! st)))
(define-key *nemacs-nav-keymap* 'CDR   (fn (st) (buffer-next! st)))
(define-key *nemacs-nav-keymap* 'BACK  (fn (st) (buffer-ascend! st)))
(define-key *nemacs-nav-keymap* 'QUOTE (fn (st) (buffer-prev! st)))
(define-key *nemacs-nav-keymap* 'ATOM  (fn (st) (buffer-to-leaf! st)))
(define-key *nemacs-nav-keymap* 'CDR   ':long-press (fn (st) (buffer-delete! st)))
(define-key *nemacs-nav-keymap* 'CONS  (fn (st) (buffer-wrap! st)))
(define-key *nemacs-nav-keymap* 'LINK  (fn (st) (buffer-splice! st)))
(register-keymap MODE-NEMACS-NAV *nemacs-nav-keymap*)

(provide 'editor/keymap)
