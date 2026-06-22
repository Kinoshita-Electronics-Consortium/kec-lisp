;; KEC Lisp editor tier — undo : a fixed-capacity O(1) snapshot ring.
;;
;; Part of the host-agnostic editor/REPL tier (ADR-0002). The zipper (10-zipper)
;; makes every edit return a NEW immutable location, so a snapshot is just the
;; old location *value* — no deep copy. This ring stores the last `cap` snapshots
;; for undo; push/pop are O(1). Backed by a vector (ADR-0003 containers), which
;; is exactly the O(1) ring the cons-list world lacked. When the ring is full a
;; push overwrites the oldest snapshot (bounded history, the device discipline).
;;
;; A snapshot is any value; the editor pushes zipper locations, but the ring is
;; value-agnostic. The ring record is itself a 4-slot vector:
;;   [0] storage : a vector of `cap` snapshot slots
;;   [1] head    : index of the next write (most-recent is head-1)
;;   [2] count   : number of live snapshots (0..cap)
;;   [3] cap     : capacity

;; (make-undo-ring cap) — a new empty ring holding up to cap snapshots.
(defn make-undo-ring (cap)
  (vector (make-vector cap nil) 0 0 cap))

(defn %ur-storage (r) (vector-ref r 0))
(defn %ur-head (r) (vector-ref r 1))

;; (undo-depth r) — how many snapshots can still be popped.
(defn undo-depth (r) (vector-ref r 2))

;; (undo-empty? r) — true when there is nothing to undo.
(defn undo-empty? (r) (is (vector-ref r 2) 0))

;; (undo-push r snap) — record snap as the most-recent snapshot; returns r.
;; Overwrites the oldest snapshot once `cap` is reached.
(defn undo-push (r snap)
  (let cap (vector-ref r 3))
  (let head (%ur-head r))
  (vector-set! (%ur-storage r) head snap)
  (vector-set! r 1 (mod (+ head 1) cap))
  (vector-set! r 2 (min cap (+ (vector-ref r 2) 1)))
  r)

;; (undo-pop r) — remove and return the most-recent snapshot, or nil if empty.
(defn undo-pop (r)
  (if (undo-empty? r)
      nil
      (do
        (let cap (vector-ref r 3))
        (let prev (mod (+ (- (%ur-head r) 1) cap) cap))
        (vector-set! r 1 prev)
        (vector-set! r 2 (- (vector-ref r 2) 1))
        (vector-ref (%ur-storage r) prev))))

;; (undo-peek r) — the most-recent snapshot without removing it, or nil.
(defn undo-peek (r)
  (if (undo-empty? r)
      nil
      (do
        (let cap (vector-ref r 3))
        (vector-ref (%ur-storage r) (mod (+ (- (%ur-head r) 1) cap) cap)))))

(provide 'editor/undo)
