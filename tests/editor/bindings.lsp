;; KEC Lisp editor tier — default key bindings (keymap-as-data) conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/32-text.lsp")
(load "editor/55-bindings.lsp")

(deftest "bindings/key->command lookup"
  (check (is (key-command "C-n") 'text-next-line!))
  (check (is (key-command "C-p") 'text-prev-line!))
  (check (is (key-command "C-f") 'text-forward!))
  (check (is (key-command "RET") 'text-newline!))
  (check (is (key-command "C-x C-s") 'save-buffer))
  (check (nil? (key-command "C-q"))))                ; unbound

(deftest "bindings/resolve classifies commands"
  (check (is (resolve-key "C-n") "buffer:text-next-line!"))
  (check (is (resolve-key "C-x C-c") "host:exit-editor"))
  (check (is (resolve-key "C-x C-s") "host:save-buffer"))
  (check (is (resolve-key "a") "self-insert"))       ; lone graphic key
  (check (is (resolve-key "C-q") "undefined")))      ; unbound chord

(deftest "bindings/host-command? predicate"
  (check (host-command? 'save-buffer))
  (check (host-command? 'exit-editor))
  (check (not (host-command? 'text-next-line!))))

(deftest "bindings/where-is inverts the map"
  (let keys (where-is 'text-next-line!))
  (check (not (nil? (member "C-n" keys))))
  (check (not (nil? (member "<down>" keys))))        ; next-line has two bindings
  (check (nil? (where-is 'no-such-command))))

(deftest "bindings/describe-key text"
  (check (is (describe-key "C-n") "C-n runs text-next-line!"))
  (check (is (describe-key "C-q") "C-q is undefined")))

(deftest "bindings/M-slash-is-free-for-dabbrev"
  ;; In Emacs M-/ is dabbrev-expand, not redo. It stays UNBOUND (reserved for a
  ;; future dabbrev) rather than repurposed — knEmacs copies Emacs keys exactly.
  (check (nil? (key-command "M-/")))
  (check (is (resolve-key "M-/") "undefined")))

(deftest "bindings/redo-on-emacs-undo-redo-keys"
  ;; Emacs 28+ binds undo-redo to C-M-_ and C-? — redo lives there, not on M-/.
  (check (is (key-command "C-M-_") 'text-redo!))
  (check (is (key-command "C-?") 'text-redo!))
  (check (is (resolve-key "C-M-_") "buffer:text-redo!")))

(deftest "bindings/rebinding is live (the map is data)"
  (bind-key "C-q" 'text-forward!)
  (check (is (key-command "C-q") 'text-forward!))
  (check (is (resolve-key "C-q") "buffer:text-forward!")))

;; A resolved buffer command actually drives the buffer when applied.
(deftest "bindings/resolved buffer command moves the cursor"
  (let b (text-open "t" "ab\ncd"))
  (check (is (resolve-key "C-n") "buffer:text-next-line!"))
  (text-next-line! b)                                ; the command the tag names
  (check (= (text-point-row b) 1)))
