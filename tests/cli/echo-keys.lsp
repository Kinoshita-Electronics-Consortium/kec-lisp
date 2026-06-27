;; Driven by readkey-smoke.sh. Echo each input byte's code until end-of-input
;; (read-key returns nil at EOF), then confirm poll-key returns nil — without
;; blocking — once stdin has drained.
(let k (read-key))
(while k
  (princ (number->string k)) (newline)
  (set k (read-key)))
(princ "poll:") (princ (if (poll-key 0.05) "got" "nil")) (newline)
