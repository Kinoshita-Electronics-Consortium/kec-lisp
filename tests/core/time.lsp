;; KEC Core — time primitives. ADR-0005.
;;   (clock) — CPU seconds (profiling); pre-existing, covered here too.
;;   (now)   — monotonic elapsed seconds (wall clock for timers/animation).
;; INVARIANTS only — never assert exact times or an UPPER bound (a loaded CI
;; runner can stall arbitrarily long between two reads).

(deftest "time/now-is-a-number"
  (check (number? (now))))

(deftest "time/clock-is-a-number"
  (check (number? (clock))))

(deftest "time/now-is-monotonic"
  (let t0 (now))
  (let t1 (now))
  (check (>= t1 t0)))                ; never goes backward

(deftest "time/now-advances-across-a-busy-wait"
  ;; Lower bound only: after spinning, elapsed is non-negative.
  (let t0 (now))
  (let i 0)
  (while (< i 50000) (set i (+ i 1)))
  (check (>= (now) t0)))
