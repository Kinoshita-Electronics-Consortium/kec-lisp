;; KEC Lisp editor tier — timer : an idle-timer registry (ADR-0006).
;;
;; The Lisp half of the knEmacs idle-timer (Emacs's run-with-timer). The HOST
;; owns the clock and the event loop; this registry owns only *scheduling*, in
;; abstract seconds. Every entry point takes the current absolute time `now` as
;; an argument rather than calling (now) itself — so the whole module is
;; deterministically testable against a mock clock, and the device firmware can
;; drive it from whatever clock it has.
;;
;; The host loop (cli/main.c do_nemacs) calls, each iteration:
;;   ms = (timers-poll-ms (now))   ; -1 when nothing is armed -> block as before
;;   ... poll(stdin, ms) ...
;;   on timeout: (timers-advance! (now))   ; fire due thunks, re-arm repeats
;;
;; A timer is a 4-slot vector [id due repeat fn]:
;;   id     : integer handle (for cancel-timer)
;;   due    : absolute time it next fires
;;   repeat : seconds to re-arm after firing, or nil for a one-shot
;;   fn     : thunk of no arguments, called for side effect
;;
;; Load order: after 70-lifecycle (independent — needs only Core).

(define *timers* nil)
(define *timer-seq* 0)

(defn %timer-id     (tm) (vector-ref tm 0))
(defn %timer-due    (tm) (vector-ref tm 1))
(defn %timer-repeat (tm) (vector-ref tm 2))
(defn %timer-fn     (tm) (vector-ref tm 3))

;; (run-with-timer secs repeat fn now) -> id
;; Arm `fn` to fire once at now+secs. If `repeat` is a POSITIVE number, re-arm
;; every `repeat` seconds thereafter; nil (or a non-positive number) is a
;; one-shot. The non-positive guard matters: in KEC `0` is truthy, so without it
;; a `repeat` of 0 would re-arm to now+0 (always due) and the host would spin —
;; clamp it to a one-shot instead. (A genuinely fast positive repeat is allowed;
;; the host floors its poll interval so it can't busy-spin.)
;; Returns the timer id (pass to cancel-timer).
(defn run-with-timer (secs repeat fn now)
  (set *timer-seq* (+ *timer-seq* 1))
  (let id *timer-seq*)
  (let rep (if (and repeat (> repeat 0)) repeat nil))
  (set *timers* (cons (vector id (+ now secs) rep fn) *timers*))
  id)

;; (cancel-timer id) -> id. Remove the timer with this id (no-op if absent).
(defn cancel-timer (id)
  (set *timers* (filter (fn (tm) (not (is (%timer-id tm) id))) *timers*))
  id)

;; (cancel-all-timers!) -> nil. Drop every timer (reset; handy for tests).
(defn cancel-all-timers! ()
  (set *timers* nil))

;; (timers-next-delay now) -> seconds until the soonest due timer (clamped at 0
;; for already-due timers), or nil when no timers are armed.
(defn timers-next-delay (now)
  (if (nil? *timers*)
      nil
      (do
        (let best nil)
        (for-each
          (fn (tm)
            (let d (- (%timer-due tm) now))
            (when (or (nil? best) (< d best)) (set best d)))
          *timers*)
        (max 0 best))))

;; (timers-poll-ms now) -> a poll() timeout in milliseconds: -1 when nothing is
;; armed (block forever, exactly as the editor did before any timer), else
;; max(0, …) ms until the soonest due timer. This is the value the host loop
;; hands straight to poll(); -1 keeps the no-timer path byte-identical to today.
(defn timers-poll-ms (now)
  (let d (timers-next-delay now))
  (if (nil? d) -1 (floor (* d 1000))))

;; (timers-advance! now) -> the number of timers fired. Fire every timer whose
;; due time has arrived; re-arm repeats to now+repeat, drop one-shots. The due
;; set is SNAPSHOT and the registry rebuilt BEFORE any thunk runs, so a thunk
;; may safely (cancel-timer)/(run-with-timer) mid-fire without corrupting the
;; list being walked. Two semantics worth knowing:
;;   - Cancel/add take effect for FUTURE ticks only — a timer already in this
;;     tick's due snapshot still fires this tick even if a co-due sibling thunk
;;     cancels it (matches Emacs). Don't expect same-tick suppression.
;;   - Lossy on missed periods: a due repeat fires exactly ONCE per advance and
;;     re-anchors to (+ now repeat), even if many periods elapsed (a clock jump /
;;     device wake). Missed ticks are NOT replayed — callers wanting "roughly
;;     every N seconds" are fine; callers counting ticks must not assume one fire
;;     per elapsed period.
(defn timers-advance! (now)
  (let due  (filter (fn (tm) (<= (%timer-due tm) now)) *timers*))
  (let keep (filter (fn (tm) (>  (%timer-due tm) now)) *timers*))
  (let rearmed
    (map (fn (tm) (vector (%timer-id tm) (+ now (%timer-repeat tm))
                          (%timer-repeat tm) (%timer-fn tm)))
         (filter (fn (tm) (%timer-repeat tm)) due)))
  (set *timers* (append keep rearmed))
  (for-each (fn (tm) ((%timer-fn tm))) due)     ; fire the snapshot
  (length due))

(provide 'editor/timer)
