;; KEC Core — introspection primitives: bound? and globals.
;;
;; Read-only reflection over the global environment (AMOP Ch.2, "fair use
;; rules", pp. 50-51): ask the runtime what's defined instead of reparsing
;; source. `globals` returns a FRESH list of interned symbols the caller owns
;; and must treat as read-only. `bound?` reports whether a symbol has a non-nil
;; global binding (in this Lisp nil is absence, so a symbol bound to nil reads
;; as unbound).

(deftest "introspect/bound?-kernel-and-core"
  (check (bound? 'car))            ; kernel primitive
  (check (bound? 'cons))
  (check (bound? 'map))            ; Core function
  (check (bound? 'bound?))         ; self
  (check (bound? 'globals)))

(deftest "introspect/bound?-unbound-is-nil"
  (check (not (bound? 'no-such-symbol-anywhere-xyz)))
  ;; Binding presence is distinct from the value nil.
  (set %nil-bound-probe nil)
  (check (bound? '%nil-bound-probe))
  (check (member '%nil-bound-probe (globals)))
  ;; a non-nil binding is visible
  (set %real-probe 42)
  (check (bound? '%real-probe)))

(deftest "introspect/bound?-needs-a-symbol"
  (check-err (bound? 42))
  (check-err (bound? "car")))

(deftest "introspect/globals-enumerates"
  (check (member 'car (globals)))
  (check (member 'map (globals)))
  (check (member 'globals (globals)))
  (set %enum-probe 7)              ; freshly defined names appear
  (check (member '%enum-probe (globals))))

(deftest "introspect/globals-prefix-filter"
  (check (member 'str (globals "str")))      ; every result starts with prefix
  (check (not (member 'car (globals "str"))))
  (check (not (globals "zzz-no-such-prefix"))))   ; no match -> nil

(deftest "introspect/globals-fresh-list"
  ;; fair-use: each call returns a distinct, caller-owned list (pairs compare by
  ;; identity, so two non-empty results are never `is`-equal).
  (check (not (is (globals) (globals)))))

(deftest "introspect/fn-params"
  ;; the parameter list of a closure, for describe-function-style help
  (defn two-args (a b) (+ a b))
  (check (equal? (fn-params two-args) '(a b)))
  ;; a variadic closure: params is a single symbol (rest binding)
  (set %variadic (fn args args))
  (check (is (fn-params %variadic) 'args))
  ;; a macro's parameter list is readable too
  (check (equal? (fn-params when) '(test . body)))
  ;; built-ins have no Lisp parameter list -> nil (not an error)
  (check (not (fn-params car)))           ; kernel primitive
  (check (not (fn-params type-of))))      ; host cfunc

(deftest "introspect/fn-params-fresh"
  ;; fair-use: the returned list is a copy, not a handle into the closure
  (defn probe (x y) x)
  (check (not (is (fn-params probe) (fn-params probe)))))

(deftest "introspect/fn-params-needs-a-function"
  (check-err (fn-params 42))
  (check-err (fn-params "nope")))

(deftest "introspect/protected-load-bearing-bindings"
  (check-err (set map (fn (f xs) 'BROKEN)))
  (check-err (eval (read-string "(let map (fn (f xs) 'BROKEN))")))
  (check-err (set cons (fn (a b) 'BROKEN)))
  (check-err (set %append nil))
  ;; Failed protective rebinds must leave the standard methods intact.
  (check (equal? (map (fn (x) (+ x 1)) (list 1 2 3)) (list 2 3 4)))
  (check (is (car (cons 'a 'b)) 'a))
  (check (bound? '%append)))
