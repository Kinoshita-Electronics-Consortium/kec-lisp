;; KEC Core — pred : type predicates
;;
;; nil? / pair? / even? / odd? are plain KEC Lisp. The tag tests
;; number? / symbol? / string? / fn? can't be — Fe gives no way to read a
;; value's type tag from Lisp — so they use the host primitive
;; (type-of x) -> :pair|:nil|:number|:symbol|:string|:fn|...

(defn nil?  (x) (not x))
(defn pair? (x) (not (atom x)))

(defn even? (n) (is (mod n 2) 0))   ; mod is a host primitive (kernel has none)
(defn odd?  (n) (not (even? n)))

(defn number? (x) (is (type-of x) ':number))
(defn symbol? (x) (is (type-of x) ':symbol))
(defn string? (x) (is (type-of x) ':string))
(defn fn?     (x) (is (type-of x) ':fn))
