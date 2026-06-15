;; BLACK ICE TRACE — deterministic tests for the example game.

(load "examples/black-ice-trace-lib.lsp")

(deftest "black-ice/player-and-node-records"
  (let player (bit-new-player))
  (check (is (get 'trace player) 0))
  (check (is (get 'stealth player) 3))
  (check (is (get 'credits player) 0))
  (check (is (get 'jacked-out player) nil))
  (let node (bit-node "vault" 4 160 3))
  (check (is (get 'name node) "vault"))
  (check (is (get 'status node) ':unknown)))

(deftest "black-ice/scan-crack-siphon-path"
  (let state (bit-new-state))
  (set state (bit-apply-command state 'scan 0))
  (check (is (get 'status (bit-current-node state)) ':scanned))
  (check (is (get 'trace (get 'player state)) 5))
  (set state (bit-apply-command state 'crack 0))
  (check (is (get 'status (bit-current-node state)) ':rooted))
  (set state (bit-apply-command state 'siphon 0))
  (check (is (get 'status (bit-current-node state)) ':looted))
  (check (is (get 'credits (get 'player state)) 90)))

(deftest "black-ice/spoof-pivot-and-endings"
  (let state (bit-new-state))
  (set state (bit-add-trace state 30))
  (set state (bit-apply-command state 'spoof 0))
  (check (is (get 'trace (get 'player state)) 12))
  (check (is (get 'stealth (get 'player state)) 2))
  (set state (bit-apply-command state 'pivot 2))
  (check (is (get 'current (get 'player state)) 2))
  (set state (bit-set-player state (put 'credits 320 (get 'player state))))
  (set state (bit-apply-command state 'jack-out 0))
  (check (bit-win? state))
  (let burned (bit-add-trace (bit-new-state) 100))
  (check (bit-loss? burned)))
