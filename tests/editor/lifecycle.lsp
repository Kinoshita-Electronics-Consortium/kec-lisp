;; KEC Lisp editor tier — lifecycle state machine conformance.
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/70-lifecycle.lsp")

(deftest "lifecycle/initial-state"
  (let lc (make-lifecycle))
  (check (is (lifecycle-state lc) ':init))
  (check (nil? (lifecycle-mode lc))))

(deftest "lifecycle/enter-editor-fires-enter"
  (let lc (make-lifecycle))
  (let entered nil)
  (lifecycle-add-hook lc ':enter (fn (x) (set entered (lifecycle-state x))))
  (lifecycle-enter-editor! lc)
  (check (is (lifecycle-state lc) ':editor))
  (check (is entered ':editor)))                  ; hook saw the new state

(deftest "lifecycle/enter-repl"
  (let lc (make-lifecycle))
  (lifecycle-enter-repl! lc)
  (check (is (lifecycle-state lc) ':repl)))

(deftest "lifecycle/exit-fires-exit"
  (let lc (make-lifecycle))
  (let exits 0)
  (lifecycle-add-hook lc ':exit (fn (x) (set exits (+ exits 1))))
  (lifecycle-enter-editor! lc)
  (lifecycle-exit! lc)
  (check (is (lifecycle-state lc) ':exited))
  (check (is exits 1)))                            ; only :exit fired, not :enter

(deftest "lifecycle/set-mode-fires-mode-change"
  (let lc (make-lifecycle))
  (let seen nil)
  (lifecycle-add-hook lc ':mode-change (fn (x mode) (set seen mode)))
  (lifecycle-set-mode! lc ':repl-prompt)
  (check (is (lifecycle-mode lc) ':repl-prompt))
  (check (is seen ':repl-prompt)))                 ; hook received the new mode

(deftest "lifecycle/shutdown-fires-exit"
  (let lc (make-lifecycle))
  (let exited nil)
  (lifecycle-add-hook lc ':exit (fn (x) (set exited t)))
  (lifecycle-shutdown! lc)
  (check (is (lifecycle-state lc) ':shutdown))
  (check exited))

(deftest "lifecycle/multiple-hooks-same-event"
  (let lc (make-lifecycle))
  (let n 0)
  (lifecycle-add-hook lc ':enter (fn (x) (set n (+ n 1))))
  (lifecycle-add-hook lc ':enter (fn (x) (set n (+ n 10))))
  (lifecycle-enter-editor! lc)
  (check (is n 11)))                               ; both hooks ran
