;; KEC Core — util : small definition/sequencing utilities
;;
;; Loads after the higher-order functions (50) and before strings (60).
;; Quasiquote is available by now, but these expansions are simple enough to
;; build by hand with list/cons, matching the 40-ctrl style.

;; (prog1 first rest...) — evaluate all forms, return the FIRST's value.
;; Bind the first value to a gensym temp, run the rest for effect, yield the temp.
(set prog1 (mac (first . rest)
  (let r (gensym))
  (list 'do
    (list 'let r first)
    (cons 'do rest)
    r)))

;; (defvar name value) — define a global only if it is currently unbound, so a
;; user/config value set earlier survives a later library load. Returns the
;; binding either way. bound? is a host primitive (nil reads as unbound).
(set defvar (mac (name value)
  (list 'if (list 'bound? (list 'quote name))
        name
        (list 'do (list 'set name value) name))))
