;; BLACK ICE TRACE — a small command-driven hacking game library.
;;
;; Records are alists. The public helper names use the `bit-` prefix so the
;; example can be loaded into a normal KEC session without stealing common names.

(defn bit-node (name security data ice)
  (list (cons 'name name)
        (cons 'security security)
        (cons 'data data)
        (cons 'ice ice)
        (cons 'status ':unknown)))

(defn bit-default-network ()
  (list (bit-node "payroll-gateway" 2 90 1)
        (bit-node "mail-scrubber" 3 80 2)
        (bit-node "identity-vault" 4 160 3)
        (bit-node "ops-jumpbox" 3 110 2)
        (bit-node "archive-coldstore" 5 220 4)))

(defn bit-new-player ()
  (list (cons 'trace 0)
        (cons 'stealth 3)
        (cons 'credits 0)
        (cons 'turn 0)
        (cons 'current 0)
        (cons 'jacked-out nil)))

(defn bit-new-state ()
  (list (cons 'player (bit-new-player))
        (cons 'nodes (bit-default-network))
        (cons 'message "Fresh jack. Pick a node, stay quiet, get paid.")))

(defn bit-clamp (n lo hi)
  (max lo (min hi n)))

(defn bit-replace-nth (xs idx value)
  (let out nil)
  (let i 0)
  (while xs
    (if (is i idx)
        (set out (cons value out))
        (set out (cons (car xs) out)))
    (set i (+ i 1))
    (set xs (cdr xs)))
  (reverse out))

(defn bit-set-player (state player)
  (put 'player player state))

(defn bit-set-message (state message)
  (put 'message message state))

(defn bit-current-node (state)
  (nth (get 'nodes state) (get 'current (get 'player state))))

(defn bit-set-current-node (state node)
  (let player (get 'player state))
  (let idx (get 'current player))
  (put 'nodes (bit-replace-nth (get 'nodes state) idx node) state))

(defn bit-add-trace (state amount)
  (let player (get 'player state))
  (let trace (bit-clamp (+ (get 'trace player) amount) 0 100))
  (bit-set-player state (put 'trace trace player)))

(defn bit-inc-turn (state)
  (let player (get 'player state))
  (bit-set-player state (put 'turn (+ (get 'turn player) 1) player)))

(defn bit-node-known? (node)
  (not (is (get 'status node) ':unknown)))

(defn bit-win? (state)
  (let player (get 'player state))
  (and (get 'jacked-out player) (>= (get 'credits player) 300)))

(defn bit-loss? (state)
  (let player (get 'player state))
  (and (not (get 'jacked-out player)) (>= (get 'trace player) 100)))

(defn bit-game-over? (state)
  (or (bit-win? state) (bit-loss? state) (get 'jacked-out (get 'player state))))

(defn bit-scan (state)
  (let node (bit-current-node state))
  (if (bit-node-known? node)
      (do
        (set state (bit-add-trace state 2))
        (bit-set-message state "You sweep the same host again. Nothing new, more noise."))
      (do
        (set node (put 'status ':scanned node))
        (set state (bit-set-current-node state node))
        (set state (bit-add-trace state 5))
        (bit-set-message state (format "Scan complete: %s exposes %d data blocks."
                                       (get 'name node)
                                       (get 'data node))))))

(defn bit-crack (state roll)
  (let node (bit-current-node state))
  (cond
    ((is (get 'status node) ':unknown)
     (bit-set-message (bit-add-trace state 8) "Blind exploit fizzles. Scan first."))
    ((or (is (get 'status node) ':rooted) (is (get 'status node) ':looted))
     (bit-set-message (bit-add-trace state 2) "Root shell already lives here."))
    (else
      (let strength (+ 3 roll))
      (if (>= strength (get 'security node))
          (do
            (set node (put 'status ':rooted node))
            (set state (bit-set-current-node state node))
            (set state (bit-add-trace state (+ 6 (get 'ice node))))
            (bit-set-message state (format "Exploit lands. %s is rooted."
                                           (get 'name node))))
          (do
            (set state (bit-add-trace state (+ 14 (* 2 (get 'ice node)))))
            (bit-set-message state "Exploit burns hot. BLACK ICE starts a trace."))))))

(defn bit-siphon (state)
  (let node (bit-current-node state))
  (if (is (get 'status node) ':rooted)
      (do
        (let player (get 'player state))
        (set player (put 'credits (+ (get 'credits player) (get 'data node)) player))
        (set node (put 'status ':looted node))
        (set state (bit-set-current-node state node))
        (set state (bit-set-player state player))
        (set state (bit-add-trace state (+ 4 (get 'ice node))))
        (bit-set-message state (format "Data siphoned: +%d credits from %s."
                                       (get 'data node)
                                       (get 'name node))))
      (bit-set-message (bit-add-trace state 4) "No root, no loot. Crack the host first.")))

(defn bit-spoof (state)
  (let player (get 'player state))
  (if (<= (get 'stealth player) 0)
      (bit-set-message (bit-add-trace state 6) "Spoof cache empty. The network notices.")
      (do
        (set player (put 'stealth (- (get 'stealth player) 1) player))
        (set state (bit-set-player state player))
        (set state (bit-add-trace state -18))
        (bit-set-message state "Spoofed telemetry. Trace sinks by 18."))))

(defn bit-pivot (state idx)
  (if (and (>= idx 0) (< idx (length (get 'nodes state))))
      (do
        (let player (get 'player state))
        (set player (put 'current idx player))
        (set state (bit-set-player state player))
        (set state (bit-add-trace state 3))
        (bit-set-message state (format "Pivoted to node %d." idx)))
      (bit-set-message state "No such node on this net.")))

(defn bit-jack-out (state)
  (let player (get 'player state))
  (set player (put 'jacked-out 1 player))
  (set state (bit-set-player state player))
  (if (>= (get 'credits player) 300)
      (bit-set-message state "Clean disconnect. Contract fulfilled.")
      (bit-set-message state "You cut the line early. Alive, but under quota.")))

(defn bit-command-symbol (s)
  (cond ((is s "scan") 'scan)
        ((is s "crack") 'crack)
        ((is s "siphon") 'siphon)
        ((is s "spoof") 'spoof)
        ((is s "pivot") 'pivot)
        ((is s "jack-out") 'jack-out)
        ((is s "jack") 'jack-out)
        ((is s "status") 'status)
        ((is s "new") 'new)
        ((is s "help") 'help)
        (else s)))

(defn bit-apply-command (state command value)
  (if (bit-game-over? state)
      (bit-set-message state "Run is already closed. Start a new one.")
      (do
        (set state
          (case command
            (scan (bit-scan state))
            (crack (bit-crack state value))
            (siphon (bit-siphon state))
            (spoof (bit-spoof state))
            (pivot (bit-pivot state value))
            (jack-out (bit-jack-out state))
            (status state)
            (else (bit-set-message state "Unknown command. Try help."))))
        (if (or (is command 'status) (is command 'help))
            state
            (bit-inc-turn state)))))

(defn bit-status-label (status)
  (case status
    (:unknown "????")
    (:scanned "scan")
    (:rooted "root")
    (:looted "loot")
    (else (str status))))

(defn bit-node-line (idx node current)
  (format "%s %d  %s  sec:%d ice:%d data:%s status:%s"
          (if (is idx current) ">" " ")
          idx
          (if (bit-node-known? node) (get 'name node) "[redacted]")
          (get 'security node)
          (get 'ice node)
          (if (bit-node-known? node) (number->string (get 'data node)) "???")
          (bit-status-label (get 'status node))))

(defn bit-render (state)
  (let player (get 'player state))
  (let lines (list "== BLACK ICE TRACE =="
                   (format "turn:%d trace:%d/100 stealth:%d credits:%d/300"
                           (get 'turn player)
                           (get 'trace player)
                           (get 'stealth player)
                           (get 'credits player))
                   (str "message: " (get 'message state))
                   ""
                   "network:"))
  (let idx 0)
  (dolist (node (get 'nodes state))
    (set lines (append lines (list (bit-node-line idx node (get 'current player)))))
    (set idx (+ idx 1)))
  (set lines
    (append lines
            (list ""
                  "commands: scan | crack | siphon | spoof | pivot N | jack-out | new | help")))
  (cond
    ((bit-win? state)
     (set lines (append lines (list "" "WIN: You sell the dump before the trace resolves."))))
    ((bit-loss? state)
     (set lines (append lines (list "" "LOSS: Trace hits 100. The terminal goes cold."))))
    ((get 'jacked-out player)
     (set lines (append lines (list "" "RUN CLOSED: Under quota, but still breathing.")))))
  (join lines "\n"))

(defn bit-print-render (state)
  (princ (bit-render state))
  (newline))

(defn bit-help-text ()
  (join (list "BLACK ICE TRACE"
              ""
              "Goal: collect at least 300 credits, then jack-out before trace reaches 100."
              ""
              "scan       reveal the current node"
              "crack [N]  root a scanned node; boost hard targets with 1 or 2"
              "siphon     steal data from a rooted node"
              "spoof      spend 1 stealth to drop trace by 18"
              "pivot N    move to node N"
              "jack-out   end the run"
              "new        reset the saved run"
              ""
              "Example: kec run examples/black-ice-trace.lsp crack 2")
        "\n"))
