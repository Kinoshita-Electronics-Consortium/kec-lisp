;; KEC Core — pred : type predicates (standard §4.7)
;;
;; nil? / pair? / even? / odd? are pure KEC Lisp. The tag tests
;; number? / symbol? / string? / fn? cannot be — Fe exposes no type-tag
;; introspection from Lisp — so they ride on the one host primitive Core
;; requires: (type-of x) -> :pair|:nil|:number|:symbol|:string|:fn|...
;; (standard §4.7 ⚙ FFI; ADR-0037 follow-on #2).

(defn nil?  (x) (not x))
(defn pair? (x) (not (atom x)))

(defn even? (n) (is (mod n 2) 0))   ; mod is a host primitive (kernel has none)
(defn odd?  (n) (not (even? n)))

(defn number? (x) (is (type-of x) ':number))
(defn symbol? (x) (is (type-of x) ':symbol))
(defn string? (x) (is (type-of x) ':string))
(defn fn?     (x) (is (type-of x) ':fn))
