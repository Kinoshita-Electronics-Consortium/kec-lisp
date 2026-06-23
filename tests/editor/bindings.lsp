;; KEC Lisp editor tier — default key bindings (keymap-as-data) conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/50-keymap.lsp")
(load "editor/55-bindings.lsp")

(deftest "bindings/key->command lookup"
  (check (is (key-command "C-n") 'buffer-line-next!))
  (check (is (key-command "C-p") 'buffer-line-prev!))
  (check (is (key-command "C-M-f") 'buffer-next!))
  (check (is (key-command "C-x C-s") 'save-buffer))
  (check (nil? (key-command "C-q"))))                ; unbound

(deftest "bindings/resolve classifies commands"
  (check (is (resolve-key "C-n") "buffer:buffer-line-next!"))
  (check (is (resolve-key "C-x C-c") "host:exit-editor"))
  (check (is (resolve-key "C-x C-s") "host:save-buffer"))
  (check (is (resolve-key "a") "self-insert"))       ; lone graphic key
  (check (is (resolve-key "C-q") "undefined")))      ; unbound chord

(deftest "bindings/host-command? predicate"
  (check (host-command? 'save-buffer))
  (check (host-command? 'exit-editor))
  (check (not (host-command? 'buffer-line-next!))))

(deftest "bindings/where-is inverts the map"
  (let keys (where-is 'buffer-undo!))
  (check (not (nil? (member "C-/" keys))))
  (check (not (nil? (member "C-_" keys))))           ; undo has two bindings
  (check (nil? (where-is 'no-such-command))))

(deftest "bindings/describe-key text"
  (check (is (describe-key "C-n") "C-n runs buffer-line-next!"))
  (check (is (describe-key "C-q") "C-q is undefined")))

(deftest "bindings/rebinding is live (the map is data)"
  (bind-key "C-q" 'buffer-undo!)
  (check (is (key-command "C-q") 'buffer-undo!))
  (check (is (resolve-key "C-q") "buffer:buffer-undo!")))

;; A resolved buffer command actually drives the buffer when applied.
(deftest "bindings/resolved buffer command moves the cursor"
  (let b (make-buffer "t" (read-all "(a b c)")))
  (check (is (resolve-key "C-M-d") "buffer:buffer-descend!"))
  (buffer-descend! b)                                ; the command the tag names
  (check (is (buffer-focus b) 'a)))
