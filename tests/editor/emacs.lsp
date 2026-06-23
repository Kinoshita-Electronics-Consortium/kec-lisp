;; KEC Lisp editor tier — default Emacs keymap (keymap-as-data) conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/50-keymap.lsp")
(load "editor/55-emacs.lsp")

(deftest "emacs/key->command lookup"
  (check (is (emacs-key-command "C-n") 'buffer-line-next!))
  (check (is (emacs-key-command "C-p") 'buffer-line-prev!))
  (check (is (emacs-key-command "C-M-f") 'buffer-next!))
  (check (is (emacs-key-command "C-x C-s") 'save-buffer))
  (check (nil? (emacs-key-command "C-z"))))          ; unbound

(deftest "emacs/resolve classifies commands"
  (check (is (emacs-resolve "C-n") "buffer:buffer-line-next!"))
  (check (is (emacs-resolve "C-x C-c") "host:exit-editor"))
  (check (is (emacs-resolve "C-x C-s") "host:save-buffer"))
  (check (is (emacs-resolve "a") "self-insert"))     ; lone graphic key
  (check (is (emacs-resolve "C-z") "undefined")))    ; unbound chord

(deftest "emacs/host-command? predicate"
  (check (emacs-host-command? 'save-buffer))
  (check (emacs-host-command? 'exit-editor))
  (check (not (emacs-host-command? 'buffer-line-next!))))

(deftest "emacs/where-is inverts the map"
  (let keys (emacs-where-is 'buffer-undo!))
  (check (not (nil? (member "C-/" keys))))
  (check (not (nil? (member "C-_" keys))))           ; undo has two bindings
  (check (nil? (emacs-where-is 'no-such-command))))

(deftest "emacs/describe-key text"
  (check (is (emacs-describe-key "C-n") "C-n runs buffer-line-next!"))
  (check (is (emacs-describe-key "C-z") "C-z is undefined")))

(deftest "emacs/rebinding is live (keymap is data)"
  (emacs-define-key "C-z" 'buffer-undo!)
  (check (is (emacs-key-command "C-z") 'buffer-undo!))
  (check (is (emacs-resolve "C-z") "buffer:buffer-undo!")))

;; A resolved buffer command actually drives the buffer when applied.
(deftest "emacs/resolved buffer command moves the cursor"
  (let b (make-buffer "t" (read-all "(a b c)")))
  (check (is (emacs-resolve "C-M-d") "buffer:buffer-descend!"))
  (buffer-descend! b)                                ; the command the tag names
  (check (is (buffer-focus b) 'a)))
