;; KEC Lisp editor tier — emacs : the default Emacs keymap, as DATA (field-notes A.1).
;;
;; Part of the editor/REPL tier (ADR-0002). This is the architectural payoff of
;; "keys -> named commands -> Lisp functions, via keymaps that are DATA, not a C
;; switch": one hash table maps canonical Emacs key notation ("C-n", "C-M-f",
;; "C-x C-s") to a command SYMBOL, and a terminal host dispatches a normalized
;; keystroke through it with no command knowledge of its own. Because the binding
;; table is data, describe-key / where-is are a few lines of introspection.
;;
;; DEVICE-AGNOSTIC: keys are Emacs notation and commands are editor-tier functions
;; (buffer-*). The device's own physical-key grammar lives in its host, not here;
;; this module never mentions hardware.
;;
;; A command symbol is either a BUFFER command — an editor verb of one argument
;; (the buffer), applied for its effect — or a HOST command (save / exit / eval),
;; which the host performs because it owns terminal + file I/O. `emacs-resolve`
;; classifies a key into one of: "buffer:<cmd>", "host:<cmd>", "self-insert"
;; (an unbound single graphic key), or "undefined".
;;
;; Load order: after 30-buffer (the command symbols name its verbs).

;; ----- the keymap: key-string -> command symbol -------------------------
(define *emacs-keymap* (make-hash-table))

;; (emacs-define-key key cmd) -> bind a key-string to a command symbol; returns key.
(defn emacs-define-key (key cmd) (hash-set! *emacs-keymap* key cmd) key)

;; (emacs-key-command key) -> the command symbol bound to key, or nil (describe-key).
(defn emacs-key-command (key) (hash-ref *emacs-keymap* key))

;; (emacs-where-is cmd) -> the list of key-strings bound to command `cmd`.
(defn emacs-where-is (cmd)
  (let out nil)
  (for-each (fn (pair) (when (is (cdr pair) cmd) (set out (cons (car pair) out))))
            (hash->alist *emacs-keymap*))
  out)

;; ----- host vs buffer commands ------------------------------------------
;; HOST commands need terminal/file I/O, so the host runs them; everything else
;; is a buffer verb the dispatcher applies as (cmd buffer).
(define *emacs-host-commands* (list 'save-buffer 'exit-editor 'eval-current 'keyboard-quit))
(defn emacs-host-command? (cmd) (if (member cmd *emacs-host-commands*) t nil))

;; (emacs-resolve key) -> a tag string telling the host what to do:
;;   "buffer:<cmd>"  apply the editor verb <cmd> to the buffer
;;   "host:<cmd>"    a host-I/O command — the host performs it
;;   "self-insert"   key is an unbound single graphic char — self-insert it
;;   "undefined"     an unbound key sequence
(defn emacs-resolve (key)
  (let cmd (hash-ref *emacs-keymap* key))
  (if (nil? cmd)
      (if (is (string-length key) 1) "self-insert" "undefined")
      (string-append (if (emacs-host-command? cmd) "host:" "buffer:")
                     (symbol->string cmd))))

;; (emacs-describe-key key) -> the echo-area line for C-h k: "C-n runs ...".
(defn emacs-describe-key (key)
  (let cmd (hash-ref *emacs-keymap* key))
  (if (nil? cmd)
      (string-append key " is undefined")
      (string-append key " runs " (symbol->string cmd))))

;; ----- the default bindings ---------------------------------------------
;; Basic motion (Emacs C-n / C-p by rendered line; sexp on the C-M-* family).
(emacs-define-key "C-n"     'buffer-line-next!)   ; next-line  (down)
(emacs-define-key "C-p"     'buffer-line-prev!)   ; previous-line (up)
(emacs-define-key "<down>"  'buffer-line-next!)
(emacs-define-key "<up>"    'buffer-line-prev!)
(emacs-define-key "C-M-f"   'buffer-next!)        ; forward-sexp  (next sibling)
(emacs-define-key "C-M-b"   'buffer-prev!)        ; backward-sexp (prev sibling)
(emacs-define-key "C-M-n"   'buffer-next!)        ; forward-list
(emacs-define-key "C-M-p"   'buffer-prev!)        ; backward-list
(emacs-define-key "<right>" 'buffer-next!)
(emacs-define-key "<left>"  'buffer-prev!)
(emacs-define-key "C-M-d"   'buffer-descend!)     ; down-list
(emacs-define-key "C-M-u"   'buffer-ascend!)      ; backward-up-list
;; Structural edits (paredit-flavored).
(emacs-define-key "C-M-k"   'buffer-delete!)      ; kill-sexp
(emacs-define-key "C-M-t"   'buffer-transpose!)   ; transpose-sexps
(emacs-define-key "M-("     'buffer-wrap!)        ; paredit-wrap-round
(emacs-define-key "M-s"     'buffer-splice!)      ; paredit-splice-sexp
(emacs-define-key "C-/"     'buffer-undo!)        ; undo
(emacs-define-key "C-_"     'buffer-undo!)        ; undo (alt)
;; Host-I/O commands (the host performs these).
(emacs-define-key "C-x C-s" 'save-buffer)
(emacs-define-key "C-x C-c" 'exit-editor)
(emacs-define-key "C-x C-e" 'eval-current)
(emacs-define-key "C-g"     'keyboard-quit)

(provide 'editor/emacs)
