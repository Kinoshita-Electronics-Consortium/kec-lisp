;; KEC Core — seedable RNG (ADR-0001 E).
;; The PRNG is self-contained (SplitMix64), so a fixed seed yields a fixed
;; sequence on every platform — reproducibility is the load-bearing property
;; (deck-state-seeded mission generation).

;; Collect K draws of (rand-int 1000) after seeding with n.
(defn %rng-seq (n k)
  (set-seed! n)
  (let acc nil)
  (dotimes (i k)
    (set acc (cons (rand-int 1000) acc)))
  (reverse acc))

(deftest "rng/reproducible-same-seed"
  (let a (%rng-seq 42 8))
  (let b (%rng-seq 42 8))
  (check (equal? a b)))

(deftest "rng/different-seeds-differ"
  (let a (%rng-seq 42 8))
  (let b (%rng-seq 43 8))
  (check (not (equal? a b))))

(deftest "rng/rand-int-zero"
  (set-seed! 1)
  (check (is (rand-int 0) 0))
  (check (is (rand-int -5) 0)))

(deftest "rng/set-seed-returns-seed"
  (check (is (set-seed! 7) 7)))

(deftest "rng/rand-in-unit-interval"
  (set-seed! 99)
  (dotimes (i 16)
    (let r (rand))
    (check (<= 0 r))
    (check (< r 1))))

(deftest "rng/golden-first-value"
  ;; Self-contained PRNG => a fixed seed has a fixed first draw everywhere.
  ;; SplitMix64 seeded with 42, first (rand-int 1000) -> 739.
  (set-seed! 42)
  (check (is (rand-int 1000) 739)))

(deftest "rng/rejects-non-integer-inputs"
  (check-err (set-seed! 1.5))
  (check-err (rand-int 10.5)))
