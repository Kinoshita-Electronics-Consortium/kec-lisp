;; KEC Core — trig host primitives (sin/cos/tan/atan2) + pi/tau constants.
;; ADR-0005. fe_Number is single-precision float, so trig carries ~1e-7 relative
;; error and pi is good to ~7 digits: assert with an EPSILON, never (is ...).

(deftest "math/pi-tau-constants"
  (check (< (abs (- pi 3.14159265)) 0.0001))
  (check (< (abs (- tau 6.2831853)) 0.0001))
  (check (< (abs (- tau (* 2 pi))) 0.0001)))   ; tau = 2*pi

(deftest "math/sin-cos-known-points"
  (check (< (abs (- (sin 0) 0)) 0.001))
  (check (< (abs (- (cos 0) 1)) 0.001))
  (check (< (abs (- (sin (/ pi 2)) 1)) 0.001))
  (check (< (abs (- (cos pi) -1)) 0.001))
  (check (< (abs (- (sin pi) 0)) 0.001)))      ; ~1e-7, comfortably within eps

(deftest "math/pythagorean-identity"
  (check (< (abs (- (+ (pow (sin 0.7) 2) (pow (cos 0.7) 2)) 1)) 0.001))
  (check (< (abs (- (+ (pow (sin 2.4) 2) (pow (cos 2.4) 2)) 1)) 0.001)))

(deftest "math/tan"
  (check (< (abs (- (tan 0) 0)) 0.001))
  (check (< (abs (- (tan (/ pi 4)) 1)) 0.001)))

(deftest "math/atan2-quadrants"
  ;; atan2 takes (y x) like C; check known angles within eps.
  (check (< (abs (- (atan2 0 1) 0)) 0.001))           ; +x axis  -> 0
  (check (< (abs (- (atan2 1 0) (/ pi 2))) 0.001))     ; +y axis  -> pi/2
  (check (< (abs (- (atan2 1 1) (/ pi 4))) 0.001))     ; first quadrant -> pi/4
  (check (< (abs (- (atan2 0 -1) pi)) 0.001)))         ; -x axis  -> pi

(deftest "math/sin-is-radians"
  ;; A full turn of tau returns to ~0 — confirms the argument is radians.
  (check (< (abs (- (sin tau) 0)) 0.001)))
