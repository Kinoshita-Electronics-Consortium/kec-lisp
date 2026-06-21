;; KEC Core — plist : symbol property registry (get-prop / put-prop).
;;
;; Classic Lisp symbol properties, kept in a side registry (Fe symbols have no
;; plist slot). The idiomatic home for per-symbol metadata nEmacs/kec-mode want:
;; per-symbol indentation rules (`lisp-indent-function`), a command's docstring,
;; a `disabled` flag. Named *-prop because 25-alist already owns get/put for
;; association lists. Keys and symbols compare by identity (`is`).

(deftest "plist/put-then-get"
  (put-prop 'forward-char 'doc "Move point forward one character.")
  (check (is (get-prop 'forward-char 'doc) "Move point forward one character."))
  (put-prop 'let 'indent 'body)
  (check (is (get-prop 'let 'indent) 'body)))

(deftest "plist/absent-is-nil"
  (check (not (get-prop 'never-put-this 'doc)))     ; unknown symbol
  (put-prop 'has-one-prop 'a 1)
  (check (not (get-prop 'has-one-prop 'b))))        ; known symbol, unknown key

(deftest "plist/update-in-place"
  (put-prop 'mode 'state 'off)
  (check (is (get-prop 'mode 'state) 'off))
  (put-prop 'mode 'state 'on)                        ; overwrite, don't duplicate
  (check (is (get-prop 'mode 'state) 'on)))

(deftest "plist/multiple-keys-per-symbol"
  (put-prop 'dotimes 'indent 'body)
  (put-prop 'dotimes 'doc "Loop a fixed number of times.")
  (check (is (get-prop 'dotimes 'indent) 'body))
  (check (is (get-prop 'dotimes 'doc) "Loop a fixed number of times.")))

(deftest "plist/put-returns-value"
  (check (is (put-prop 'x 'k 99) 99)))
