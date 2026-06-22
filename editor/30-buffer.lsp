;; KEC Lisp editor tier — buffer : the L1 buffer record over the zipper.
;;
;; Part of the editor/REPL tier (ADR-0002). Wraps the bare zipper cursor
;; (10-zipper) with the rest of the L1 buffer state — clipboard, modified flag,
;; buffer name — and an undo ring (20-undo), exposing verb WRAPPERS that thread
;; the clipboard, set the modified flag, and snapshot for undo. Navigation moves
;; the cursor only (no undo, no modified); structural edits snapshot + mark
;; modified. The cursor itself stays an immutable zipper location; the record is
;; a small mutable vector so the host holds one handle per open buffer.
;;
;; Load order: after 10-zipper and 20-undo.
;;
;; record = vector [loc clipboard modified? name undo-ring]

(define BUFFER-UNDO-DEPTH 64)

;; (make-buffer name forms) — a buffer named `name` over the top-level `forms`
;; (a list of s-expressions, e.g. from read-all). Cursor seated on the first
;; form; clipboard empty; not modified.
(defn make-buffer (name forms)
  (vector (buffer-from-forms forms) nil nil name (make-undo-ring BUFFER-UNDO-DEPTH)))

(defn buffer-loc (b) (vector-ref b 0))
(defn buffer-clipboard (b) (vector-ref b 1))
(defn buffer-modified? (b) (vector-ref b 2))
(defn buffer-name (b) (vector-ref b 3))
(defn buffer-undo-ring (b) (vector-ref b 4))

;; (buffer-forms b) — the whole buffer back as a flat list of top-level forms.
(defn buffer-forms (b) (loc->forms (buffer-loc b)))

;; (buffer-focus b) — the subtree currently under the cursor.
(defn buffer-focus (b) (loc-focus (buffer-loc b)))

;; ----- navigation: cursor only (no undo, no modified) -------------------
(defn %buffer-move! (b loc) (vector-set! b 0 loc) b)
(defn buffer-descend! (b)  (%buffer-move! b (descend (buffer-loc b))))
(defn buffer-next! (b)     (%buffer-move! b (next-sibling (buffer-loc b))))
(defn buffer-prev! (b)     (%buffer-move! b (prev-sibling (buffer-loc b))))
(defn buffer-ascend! (b)   (%buffer-move! b (ascend (buffer-loc b))))
(defn buffer-to-leaf! (b)  (%buffer-move! b (descend-to-leaf (buffer-loc b))))

;; ----- structural edits: snapshot for undo, then mark modified ----------
;; Snapshot the CURRENT location before the edit, so undo restores it.
(defn %buffer-edit! (b loc)
  (undo-push (buffer-undo-ring b) (buffer-loc b))
  (vector-set! b 0 loc)
  (vector-set! b 2 t)
  b)

(defn buffer-insert-leaf! (b x) (%buffer-edit! b (insert-leaf (buffer-loc b) x)))
(defn buffer-wrap! (b)          (%buffer-edit! b (wrap (buffer-loc b))))
(defn buffer-splice! (b)        (%buffer-edit! b (splice (buffer-loc b))))
(defn buffer-transpose! (b)     (%buffer-edit! b (transpose (buffer-loc b))))

;; delete: cut the focus to the clipboard, snapshot for undo, mark modified.
(defn buffer-delete! (b)
  (let r (delete-node (buffer-loc b)))   ; (new-loc . cut)
  (undo-push (buffer-undo-ring b) (buffer-loc b))
  (vector-set! b 0 (car r))
  (vector-set! b 1 (cdr r))              ; clipboard <- cut subtree
  (vector-set! b 2 t)
  b)

;; paste: insert the clipboard subtree as a sibling. No-op (returns b) when the
;; clipboard is empty.
(defn buffer-paste! (b)
  (if (nil? (buffer-clipboard b))
      b
      (%buffer-edit! b (paste (buffer-loc b) (buffer-clipboard b)))))

;; ----- undo -------------------------------------------------------------
;; Restore the most-recent snapshot (an old location). No-op when the ring is
;; empty. The cursor returns with the structure; the modified flag is left set
;; (conservative — the buffer differs from its last-saved bytes).
(defn buffer-undo! (b)
  (let snap (undo-pop (buffer-undo-ring b)))
  (if (nil? snap) b (%buffer-move! b snap)))

(defn buffer-can-undo? (b) (not (undo-empty? (buffer-undo-ring b))))

(provide 'editor/buffer)
