;; KEC Lisp editor tier — bindings : the default key bindings, as DATA (field-notes A.1).
;;
;; Part of the editor/REPL tier (ADR-0002). Where 50-keymap is the keymap ENGINE,
;; this is the default BINDING SET a terminal host runs: one hash table maps
;; canonical key notation ("C-n", "C-M-f", "C-x C-s") to a command SYMBOL, so the
;; host dispatches a normalized keystroke through it with no command knowledge of
;; its own. Because the table is data, `describe-key` / `where-is` are a few lines
;; of introspection. The bindings are knEmacs-style (we EMULATE Emacs's feel);
;; nothing here reimplements Emacs.
;;
;; DEVICE-AGNOSTIC: keys are written in plain notation and commands are editor-tier
;; functions (buffer-*). The device's own physical-key grammar (50-keymap's
;; :nemacs-nav map) lives with the device host, not here; this module never
;; mentions hardware.
;;
;; A command symbol is either a BUFFER command — an editor verb of one argument
;; (the buffer), applied for its effect — or a HOST command (save / exit / eval /
;; keyboard-quit), which the host performs because it owns terminal + file I/O.
;; `resolve-key` classifies a key into one of: "buffer:<cmd>", "host:<cmd>",
;; "self-insert" (an unbound single graphic key), or "undefined".
;;
;; Load order: after 30-buffer (the command symbols name its verbs).

;; ----- the binding table: key-string -> command symbol ------------------
(define *default-keymap* (make-hash-table))

;; (bind-key key cmd) -> bind a key-string to a command symbol; returns key.
(defn bind-key (key cmd) (hash-set! *default-keymap* key cmd) key)

;; (key-command key) -> the command symbol bound to key, or nil (the describe-key lookup).
(defn key-command (key) (hash-ref *default-keymap* key))

;; (where-is cmd) -> the list of key-strings bound to command `cmd`.
(defn where-is (cmd)
  (let out nil)
  (for-each (fn (pair) (when (is (cdr pair) cmd) (set out (cons (car pair) out))))
            (hash->alist *default-keymap*))
  out)

;; ----- host vs buffer commands ------------------------------------------
;; HOST commands need terminal/file I/O, so the host runs them; everything else
;; is a buffer verb the dispatcher applies as (cmd buffer).
(define *host-commands* (list 'save-buffer 'exit-editor 'eval-current 'keyboard-quit))
(defn host-command? (cmd) (if (member cmd *host-commands*) t nil))

;; (resolve-key key) -> a tag string telling the host what to do:
;;   "buffer:<cmd>"  apply the editor verb <cmd> to the buffer
;;   "host:<cmd>"    a host-I/O command — the host performs it
;;   "self-insert"   key is an unbound single graphic char — self-insert it
;;   "undefined"     an unbound key sequence
(defn resolve-key (key)
  (let cmd (hash-ref *default-keymap* key))
  (if (nil? cmd)
      (if (is (string-length key) 1) "self-insert" "undefined")
      (string-append (if (host-command? cmd) "host:" "buffer:")
                     (symbol->string cmd))))

;; (describe-key key) -> the echo-area line for C-h k: "C-n runs ...".
(defn describe-key (key)
  (let cmd (hash-ref *default-keymap* key))
  (if (nil? cmd)
      (string-append key " is undefined")
      (string-append key " runs " (symbol->string cmd))))

;; ----- the default bindings ---------------------------------------------
;; Basic motion (C-n / C-p by rendered line; sexp on the C-M-* family).
(bind-key "C-n"     'buffer-line-next!)   ; next-line  (down)
(bind-key "C-p"     'buffer-line-prev!)   ; previous-line (up)
(bind-key "<down>"  'buffer-line-next!)
(bind-key "<up>"    'buffer-line-prev!)
(bind-key "C-M-f"   'buffer-next!)        ; forward-sexp  (next sibling)
(bind-key "C-M-b"   'buffer-prev!)        ; backward-sexp (prev sibling)
(bind-key "C-M-n"   'buffer-next!)        ; forward-list
(bind-key "C-M-p"   'buffer-prev!)        ; backward-list
(bind-key "<right>" 'buffer-next!)
(bind-key "<left>"  'buffer-prev!)
(bind-key "C-M-d"   'buffer-descend!)     ; down-list
(bind-key "C-M-u"   'buffer-ascend!)      ; backward-up-list
;; Structural edits (paredit-flavored).
(bind-key "C-M-k"   'buffer-delete!)      ; kill-sexp
(bind-key "C-M-t"   'buffer-transpose!)   ; transpose-sexps
(bind-key "M-("     'buffer-wrap!)        ; wrap-round
(bind-key "M-s"     'buffer-splice!)      ; splice-sexp
(bind-key "C-/"     'buffer-undo!)        ; undo
(bind-key "C-_"     'buffer-undo!)        ; undo (alt)
;; Host-I/O commands (the host performs these).
(bind-key "C-x C-s" 'save-buffer)
(bind-key "C-x C-c" 'exit-editor)
(bind-key "C-x C-e" 'eval-current)
(bind-key "C-g"     'keyboard-quit)

(provide 'editor/bindings)
