;; 05-marquee — a scrolling text ticker.
;;
;; Not from a specific Torop lesson, but the most knEmacs-relevant primitive:
;; a single-row sliding window over a string is exactly what an echo-line ticker
;; or the KN-86 CIPHER-LINE scrollback needs. Wrap-around via doubling the string
;; and taking a substring window that advances one column per frame.

(load "experiments/emacs-animation/anim.lsp")

(define MSG "   KEC LISP // knEMACS ANIMATION LAB // ASCII IS THE FUTURE, YES?   ")
(define WIN 34)
(define LEN (string-length MSG))
(define DOUBLED (string-append MSG MSG))

(anim-loop 200 0.07
  (fn (i)
    (princ (ansi-home))
    (let start (mod i LEN))
    (princ (substring DOUBLED start (+ start WIN)))
    (newline)))
