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
;; record = vector [loc clipboard modified? name undo-ring literal-text]
;; literal-text is nil except while a literal value is being typed (L3.2 / L4.2):
;; the in-progress text, committed (as a leaf) or cancelled.

(define BUFFER-UNDO-DEPTH 64)

;; (make-buffer name forms) — a buffer named `name` over the top-level `forms`
;; (a list of s-expressions, e.g. from read-all). Cursor seated on the first
;; form; clipboard empty; not modified; not in literal entry.
(defn make-buffer (name forms)
  (vector (buffer-from-forms forms) nil nil name (make-undo-ring BUFFER-UNDO-DEPTH) nil))

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
;; line motion (Emacs C-n / C-p): move the cursor down / up one rendered line.
(defn buffer-line-next! (b) (%buffer-move! b (line-next (buffer-loc b))))
(defn buffer-line-prev! (b) (%buffer-move! b (line-prev (buffer-loc b))))

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

;; ----- literal entry (L3.2 / L4.2): type a value, then commit or cancel ----
(defn buffer-literal-text (b) (vector-ref b 5))
(defn buffer-in-literal? (b) (not (nil? (vector-ref b 5))))

;; (buffer-enter-literal! b) — begin composing a literal (empty pending text).
(defn buffer-enter-literal! (b) (vector-set! b 5 "") b)

;; (buffer-literal-push! b s) — append the character(s) `s` to the pending text.
(defn buffer-literal-push! (b s)
  (if (buffer-in-literal? b) (vector-set! b 5 (string-append (vector-ref b 5) s)) nil)
  b)

;; (buffer-literal-backspace! b) — drop the last character of the pending text.
(defn buffer-literal-backspace! (b)
  (let txt (vector-ref b 5))
  (if (and txt (< 0 (string-length txt)))
      (vector-set! b 5 (substring txt 0 (- (string-length txt) 1)))
      nil)
  b)

;; (buffer-cancel-literal! b) — discard the pending text, leave literal entry.
(defn buffer-cancel-literal! (b) (vector-set! b 5 nil) b)

;; (buffer-commit-literal! b) — read the pending text as a form and insert it as
;; a new leaf at the cursor, then leave literal entry. A blank/empty literal just
;; cancels. Returns b.
(defn buffer-commit-literal! (b)
  (let txt (vector-ref b 5))
  (vector-set! b 5 nil)
  (if (nil? txt)
      b
      (do
        (let form (read-string txt))
        (if (nil? form)
            b
            ;; empty buffer (cursor on the nil root): seat the first top-level form
            ;; and put the cursor on it; otherwise insert as a sibling to the right.
            (if (and (at-root? (buffer-loc b)) (nil? (buffer-focus b)))
                (%buffer-edit! b (buffer-from-forms (list form)))
                (buffer-insert-leaf! b form))))))

;; ----- current form (L4.5): the top-level form containing the cursor --------
;; Ascend to the form that is a direct child of the buffer root, for eval-current
;; (the host supplies eval — SEAM S1 — and evaluates this).
(defn buffer-current-form (b)
  (let cur (buffer-loc b))
  (while (< 1 (length (loc-crumbs cur)))
    (set cur (zip-up cur)))
  (loc-focus cur))

(provide 'editor/buffer)
