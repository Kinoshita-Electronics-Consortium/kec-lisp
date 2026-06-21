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
  ;; a symbol whose value is nil reads as unbound (nil is absence here)
  (set %nil-bound-probe nil)
  (check (not (bound? '%nil-bound-probe)))
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
