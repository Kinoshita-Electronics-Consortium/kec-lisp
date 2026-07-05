;; KEC Lisp editor tier — idle-timer registry conformance (ADR-0006).
;; Loaded relative to the repo root. Time is supplied explicitly (a MOCK clock —
;; no real (now)), so every assertion is fully deterministic.

(load "editor/72-timer.lsp")

(deftest "timer/one-shot-fires-once"
  (cancel-all-timers!)
  (let hits 0)
  (run-with-timer 1 nil (fn () (set hits (+ hits 1))) 0)
  (check (is (timers-advance! 0.5) 0))   ; not due yet
  (check (is hits 0))
  (check (is (timers-advance! 1.0) 1))   ; due at t=1
  (check (is hits 1))
  (check (is (timers-advance! 2.0) 0))   ; one-shot is gone
  (check (is hits 1)))

(deftest "timer/repeating-re-arms"
  (cancel-all-timers!)
  (let hits 0)
  (run-with-timer 1 1 (fn () (set hits (+ hits 1))) 0)
  (check (is (timers-advance! 1.0) 1)) (check (is hits 1))
  (check (is (timers-advance! 1.5) 0)) (check (is hits 1))   ; next due at t=2
  (check (is (timers-advance! 2.0) 1)) (check (is hits 2))
  (check (is (timers-advance! 3.0) 1)) (check (is hits 3)))

(deftest "timer/cancel"
  (cancel-all-timers!)
  (let hits 0)
  (let id (run-with-timer 1 1 (fn () (set hits (+ hits 1))) 0))
  (cancel-timer id)
  (check (is (timers-advance! 5.0) 0))
  (check (is hits 0)))

(deftest "timer/poll-ms-minus-one-when-empty"
  (cancel-all-timers!)
  (check (is (timers-poll-ms 0) -1))     ; nothing armed -> block forever (-1)
  (check (nil? (timers-next-delay 0))))

(deftest "timer/poll-ms-counts-down"
  (cancel-all-timers!)
  (run-with-timer 2 nil (fn () nil) 0)
  (check (is (timers-poll-ms 0) 2000))   ; 2s away
  (check (is (timers-poll-ms 1.5) 500))  ; 0.5s away
  (check (is (timers-poll-ms 3) 0)))     ; overdue -> 0 (fire now)

(deftest "timer/soonest-of-many"
  (cancel-all-timers!)
  (run-with-timer 5 nil (fn () nil) 0)
  (run-with-timer 2 nil (fn () nil) 0)
  (run-with-timer 8 nil (fn () nil) 0)
  (check (is (timers-poll-ms 0) 2000)))  ; soonest of the three

(deftest "timer/non-positive-repeat-is-one-shot"
  ;; In KEC 0 is truthy, so repeat 0 must be normalized to a one-shot, else it
  ;; would re-arm to now+0 (always due) and spin the host loop.
  (cancel-all-timers!)
  (let hits 0)
  (run-with-timer 1 0 (fn () (set hits (+ hits 1))) 0)     ; repeat 0 -> one-shot
  (check (is (timers-advance! 1.0) 1)) (check (is hits 1))
  (check (is (timers-advance! 2.0) 0)) (check (is hits 1))  ; did NOT re-arm
  (check (is (timers-poll-ms 5) -1))                        ; registry empty again
  (run-with-timer 1 -3 (fn () nil) 0)                       ; negative likewise
  (check (is (timers-advance! 1.0) 1))
  (check (is (timers-poll-ms 5) -1)))

(deftest "timer/raising-thunk-does-not-abort-siblings"
  ;; A thunk that raises must not skip co-due siblings or make timers-advance!
  ;; return abnormally. (*timers* is a cons stack, so the LAST registration
  ;; fires FIRST — the raiser goes second to fire ahead of the counter.)
  (cancel-all-timers!)
  (let hits 0)
  (run-with-timer 1 nil (fn () (set hits (+ hits 1))) 0)
  (run-with-timer 1 nil (fn () (raise "boom")) 0)          ; fires first
  (check (is (timers-advance! 1.0) 2))   ; returns normally; both were due
  (check (is hits 1)))                   ; the sibling still ran

(deftest "timer/raising-repeat-is-dropped"
  ;; Failed-thunk policy: a repeating timer whose thunk raises is DROPPED, not
  ;; left armed — otherwise it would re-raise every period forever.
  (cancel-all-timers!)
  (let n 0)
  (run-with-timer 1 1 (fn () (set n (+ n 1)) (raise "boom")) 0)
  (check (is (timers-advance! 1.0) 1))
  (check (is n 1))
  (check (is (timers-poll-ms 5) -1))     ; registry empty — it was dropped
  (check (is (timers-advance! 2.0) 0))
  (check (is n 1)))                      ; never fired again

(deftest "timer/reentrancy-add-during-fire"
  (cancel-all-timers!)
  (let outer 0)
  (let inner 0)
  ;; the fired thunk arms a NEW one-shot mid-fire; the walk must not corrupt.
  (run-with-timer 1 nil
    (fn () (set outer (+ outer 1))
           (run-with-timer 1 nil (fn () (set inner (+ inner 1))) 1))
    0)
  (check (is (timers-advance! 1.0) 1)) (check (is outer 1)) (check (is inner 0))
  (check (is (timers-advance! 2.0) 1)) (check (is inner 1)))   ; the added one
