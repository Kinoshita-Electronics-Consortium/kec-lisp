;; KEC Core — math constants (ADR-0005).
;;
;; The trig primitives (sin/cos/tan/atan2) and the time primitives (now/clock)
;; are C host primitives (host/host.c); they take/return radians and seconds.
;; pi/tau live here as Core constants because kec_bind_fe registers cfuncs only,
;; and a bare constant reads more naturally than a (pi) call.
;;
;; fe_Number is single-precision float, so these are rounded to ~7 digits
;; (pi -> 3.1415927). Fine for geometry/CRT; do not rely on them for
;; high-iteration accumulation.

(define pi  3.14159265358979)   ; rounded to single-float on read
(define tau 6.28318530717959)   ; 2*pi — one full turn
