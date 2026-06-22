;; KEC Lisp editor tier — zipper : the knEmacs structural-edit data model.
;;
;; Part of the host-agnostic editor/REPL extended-library tier (ADR-0002),
;; loaded on demand by a host (the `kec` CLI, or the KN-86 firmware) — NOT baked
;; into the minimal Core. Pure KEC Lisp; runs under `kec` on a laptop.
;;
;; A buffer is a sequence of top-level forms; each form is a tree of Lisp data
;; (atoms or proper lists). The cursor is a *location* = (focus . crumbs):
;;   focus  : the subtree under the cursor (an atom or a list)
;;   crumbs : frames recording the way back up. Each frame is (left . right):
;;              left  = reversed list of the focus's left siblings
;;              right = list of the focus's right siblings, in order
;;            The parent node is reconstructable from left/focus/right.
;;
;; A Huet zipper: every move/edit returns a NEW location; nothing is mutated, so
;; the buffer is always a well-formed tree (no half-typed parens) and UNDO is an
;; O(1) snapshot — keeping an old location value, not a deep copy (see 20-undo).
;; The data-model choice (functional zipper over in-place mutation) was settled
;; by a spike: zipper undo is O(1), in-place undo is an O(nodes) copy per step.
;;
;; All spine traversal is ITERATIVE (while + index) per KEC discipline, so a deep
;; tree won't exhaust the 256-deep GC root stack on the device. Boundary moves
;; (descend into a leaf, sibling past an end, ascend past root) `raise` an
;; "invalid move: ..." error the host renders as a cue (SEAM S7).

;; ---- location accessors -----------------------------------------------------
;; loc = (focus . crumbs)
(defn loc-focus (loc) (car loc))
(defn loc-crumbs (loc) (cdr loc))
(defn make-loc (focus crumbs) (cons focus crumbs))

;; frame = (left . right) ; left is reversed
(defn frame-left (f) (car f))
(defn frame-right (f) (cdr f))
(defn make-frame (left right) (cons left right))

(defn at-root? (loc) (nil? (loc-crumbs loc)))

;; A leaf is anything that is not a pair (atom: number/symbol/string/nil).
;; nil () is treated as an empty list (descendable but with no children).
(defn branch? (x) (pair? x))

;; ---- constructor ------------------------------------------------------------
;; The buffer's "virtual root" is the list of top-level forms. We seat the
;; cursor on the FIRST top-level form, with the other forms as right siblings
;; and an empty parent frame whose existence marks "top level".
;;   forms = (f0 f1 f2 ...)
;; root location: focus=f0, crumbs=((nil . (f1 f2 ...)))
;; Ascending from a top-level form yields the whole forms list as focus with
;; empty crumbs -- the true root.
(defn buffer-from-forms (forms)
  (if (nil? forms)
      ;; empty buffer: focus is the empty forms list, already at root
      (make-loc nil nil)
      (make-loc (car forms)
                (list (make-frame nil (cdr forms))))))

;; Round-trip the WHOLE buffer back to the flat forms list (ascend fully).
(defn loc->forms (loc)
  (let cur loc)
  (while (not (at-root? cur))
    (set cur (zip-up cur)))
  ;; at root, focus is either the forms list (normal) or nil (empty buffer)
  (loc-focus cur))

;; ---- the rebuild step (zip-up one level) ------------------------------------
;; Reconstruct the parent node from the current frame, pop the frame.
(defn zip-up (loc)
  (if (at-root? loc)
      (raise "invalid move: ascend past root")
      (do
        (let crumbs (loc-crumbs loc))
        (let frame (car crumbs))
        (let left (frame-left frame))    ; reversed
        (let right (frame-right frame))
        ;; parent = (reverse left) ++ (focus : right)
        (let kids (cons (loc-focus loc) right))
        ;; prepend reversed-left iteratively
        (let l left)
        (while (pair? l)
          (set kids (cons (car l) kids))
          (set l (cdr l)))
        (make-loc kids (cdr crumbs)))))

;; ============================================================================
;; NAVIGATION  (5 verbs). On a boundary, raise "invalid move: ...".
;; ============================================================================

;; descend: move into the first child of the focus (focus must be a non-empty list)
(defn descend (loc)
  (let focus (loc-focus loc))
  (if (not (branch? focus))
      (raise "invalid move: descend into leaf")
      (do
        (let first (car focus))
        (let rest (cdr focus))
        (make-loc first
                  (cons (make-frame nil rest) (loc-crumbs loc))))))

;; next-sibling: move to the sibling to the right
(defn next-sibling (loc)
  (if (at-root? loc)
      (raise "invalid move: next-sibling at root")
      (do
        (let crumbs (loc-crumbs loc))
        (let frame (car crumbs))
        (let right (frame-right frame))
        (if (nil? right)
            (raise "invalid move: next-sibling past last")
            (do
              (let new-left (cons (loc-focus loc) (frame-left frame)))
              (let new-focus (car right))
              (let new-right (cdr right))
              (make-loc new-focus
                        (cons (make-frame new-left new-right) (cdr crumbs))))))))

;; prev-sibling: move to the sibling to the left
(defn prev-sibling (loc)
  (if (at-root? loc)
      (raise "invalid move: prev-sibling at root")
      (do
        (let crumbs (loc-crumbs loc))
        (let frame (car crumbs))
        (let left (frame-left frame))    ; reversed: car = nearest-left sibling
        (if (nil? left)
            (raise "invalid move: prev-sibling past first")
            (do
              (let new-focus (car left))
              (let new-left (cdr left))
              (let new-right (cons (loc-focus loc) (frame-right frame)))
              (make-loc new-focus
                        (cons (make-frame new-left new-right) (cdr crumbs))))))))

;; ascend: pop up to the parent (and seat focus on the parent node)
(defn ascend (loc)
  (if (at-root? loc)
      (raise "invalid move: ascend at root")
      (zip-up loc)))

;; descend-to-leaf: descend repeatedly into first child until focus is an atom
(defn descend-to-leaf (loc)
  (let cur loc)
  (while (and (branch? (loc-focus cur)) (pair? (loc-focus cur)))
    (set cur (descend cur)))
  cur)

;; ============================================================================
;; MANIPULATION verbs. Each returns (new-loc . clipboard-or-nil) where useful,
;; or just new-loc. We keep the clipboard external (the caller threads it).
;; ============================================================================

;; replace-focus: swap the focus subtree (building block for edits)
(defn replace-focus (loc new) (make-loc new (loc-crumbs loc)))

;; insert-leaf: insert atom `x` as a new sibling immediately to the RIGHT of
;; focus, and move the cursor onto it.
(defn insert-leaf (loc x)
  (if (at-root? loc)
      (raise "invalid move: cannot insert at top-level root via sibling")
      (do
        (let crumbs (loc-crumbs loc))
        (let frame (car crumbs))
        (let new-left (cons (loc-focus loc) (frame-left frame)))
        (make-loc x
                  (cons (make-frame new-left (frame-right frame)) (cdr crumbs))))))

;; delete-node: remove the focus from its parent, return (new-loc . cut).
;; Cursor lands on the right sibling if any, else the left sibling, else the
;; parent becomes an empty list and we seat on it.
(defn delete-node (loc)
  (if (at-root? loc)
      (raise "invalid move: cannot delete root")
      (do
        (let cut (loc-focus loc))
        (let crumbs (loc-crumbs loc))
        (let frame (car crumbs))
        (let left (frame-left frame))     ; reversed
        (let right (frame-right frame))
        (let new-loc
          (if (pair? right)
              ;; land on right sibling
              (make-loc (car right)
                        (cons (make-frame left (cdr right)) (cdr crumbs)))
              (if (pair? left)
                  ;; land on (previous) left sibling, now the last
                  (make-loc (car left)
                            (cons (make-frame (cdr left) nil) (cdr crumbs)))
                  ;; no siblings: parent becomes empty; ascend to it as nil-list
                  (make-loc nil (cdr crumbs)))))
        (cons new-loc cut))))

;; paste: insert clipboard subtree `clip` as a new sibling to the RIGHT and
;; move onto it. (Atoms and lists both fine.)
(defn paste (loc clip)
  (if (at-root? loc)
      (raise "invalid move: cannot paste at top-level root")
      (do
        (let crumbs (loc-crumbs loc))
        (let frame (car crumbs))
        (let new-left (cons (loc-focus loc) (frame-left frame)))
        (make-loc clip
                  (cons (make-frame new-left (frame-right frame)) (cdr crumbs))))))

;; wrap: replace focus with a single-element list containing the old focus,
;; and seat the cursor on the old focus (now the sole child of the wrapper).
;; e.g. focus = x  ==>  focus = x, but parent now has (x) where x was.
(defn wrap (loc)
  (let old (loc-focus loc))
  ;; new focus is the wrapper list (old) ; descend into it so cursor stays on old
  (descend (replace-focus loc (list old))))

;; splice: focus must be a list; replace it in its parent by its children
;; (splice them in). Cursor lands on the first spliced child, or on the right
;; sibling / parent if the list was empty.
(defn splice (loc)
  (let focus (loc-focus loc))
  (if (not (branch? focus))
      (raise "invalid move: splice non-list")
      (if (at-root? loc)
          (raise "invalid move: cannot splice top-level root")
          (do
            (let crumbs (loc-crumbs loc))
            (let frame (car crumbs))
            (let left (frame-left frame))     ; reversed
            (let right (frame-right frame))
            (let kids focus)                  ; the children to splice in
            (if (nil? kids)
                ;; empty list: equivalent to delete-node
                (car (delete-node loc))
                (do
                  ;; new focus = first child; remaining children become right
                  ;; siblings *before* the original right siblings.
                  (let new-focus (car kids))
                  (let new-right (append (cdr kids) right))
                  (make-loc new-focus
                            (cons (make-frame left new-right) (cdr crumbs)))))))))

;; transpose: swap focus with its NEXT sibling, keeping cursor on focus.
(defn transpose (loc)
  (if (at-root? loc)
      (raise "invalid move: transpose at root")
      (do
        (let crumbs (loc-crumbs loc))
        (let frame (car crumbs))
        (let right (frame-right frame))
        (if (nil? right)
            (raise "invalid move: transpose past last")
            (do
              (let sib (car right))
              (let rest (cdr right))
              ;; new order around cursor: sib goes to left, focus stays focus,
              ;; but visually focus moves right of sib. We keep cursor ON focus:
              ;; left' = (sib . left), right' = rest, focus unchanged.
              (make-loc (loc-focus loc)
                        (cons (make-frame (cons sib (frame-left frame)) rest)
                              (cdr crumbs))))))))

;; ---- invariant check --------------------------------------------------------
;; Round-trip the buffer to its flat printed form and read it back; the parsed
;; structure must be `equal?` to the live forms list. Proves well-formedness:
;; a malformed (improper / cyclic) tree could not print+reparse identically.
(defn buffer-wellformed? (loc expected-forms)
  (let forms (loc->forms loc))
  (let printed (repr forms))
  (let reparsed (read-string printed))
  (and (equal? forms reparsed)
       (if (nil? expected-forms) 1 (equal? forms expected-forms))))

(provide 'editor/zipper)
