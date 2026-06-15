;; KEC Core — error : small error value vocabulary

(defn error (message)
  (cons ':error message))

(defn error? (x)
  (and (pair? x) (is (car x) ':error)))

(defn error-message (e)
  (cdr e))
