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
;; Load order: after 32-text (the command symbols name its text-buffer verbs).

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

;; ----- the default bindings (knEmacs text-editing defaults) --------------
;; Character + line motion over the text buffer (32-text). C-f/C-b/C-n/C-p and
;; the arrow keys are the standard Emacs cursor motions; C-a/C-e are line ends.
(bind-key "C-f"     'text-forward!)       ; forward-char
(bind-key "C-b"     'text-backward!)      ; backward-char
(bind-key "<right>" 'text-forward!)
(bind-key "<left>"  'text-backward!)
(bind-key "C-n"     'text-next-line!)     ; next-line  (down)
(bind-key "C-p"     'text-prev-line!)     ; previous-line (up)
(bind-key "<down>"  'text-next-line!)
(bind-key "<up>"    'text-prev-line!)
(bind-key "C-a"     'text-bol!)           ; move-beginning-of-line
(bind-key "C-e"     'text-eol!)           ; move-end-of-line
;; Editing: newline + the two deletes. (Self-insert of graphic keys is handled
;; by the host directly — an unbound single graphic key resolves to "self-insert".)
(bind-key "RET"     'text-newline!)       ; newline
(bind-key "DEL"     'text-backspace!)     ; delete-backward-char (Backspace)
(bind-key "C-d"     'text-delete!)        ; delete-char (forward)
(bind-key "TAB"     'text-insert-tab!)    ; indent: soft spaces to the next stop
;; Host-I/O commands (the host performs these).
(bind-key "C-x C-s" 'save-buffer)
(bind-key "C-x C-c" 'exit-editor)
(bind-key "C-g"     'keyboard-quit)

(provide 'editor/bindings)
