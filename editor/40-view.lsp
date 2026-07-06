;; KEC Lisp editor tier — view : the abstract view model (SEAM S4).
;;
;; Part of the editor/REPL tier (ADR-0002). LIB emits an abstract view model;
;; the host paints it (S4). The shapes here are robbed from the KN-86 nEmacs
;; screen's seam (kn-86 .../lib/nemacs/nemacs.lsp), so that device screen can
;; drive THIS Lisp engine in place of its C cores:
;;   (buffer->view b) -> (root-node . cursor-node)   ; cf. nemacs/tree + /cursor
;;   (buffer-modeline b) -> string                    ; cf. nemacs/modeline
;;   (buffer-echo b)     -> string                    ; cf. nemacs/echo
;;   (completion-signature token) -> string | nil     ; cf. nemacs/signature-for
;; A view node is (label . children): label is a display string, children is a
;; list of child view nodes (nil for a leaf) — exactly the ui/tree node shape.
;;
;; Load order: after 10-zipper and 30-buffer.

(define VIEW-LABEL-MAX 28)   ; node label preview width (cells)

(defn %view-truncate (s n)
  (if (<= (string-length s) n)
      s
      (string-append (substring s 0 (- n 3)) "...")))

;; Each node is labelled by a truncated print of its subtree — a structural
;; preview, so a list shows what it contains without head-extraction guessing.
(defn %node-label (form) (%view-truncate (repr form) VIEW-LABEL-MAX))

;; (form->view form) -> (label . children)
;; ITERATIVE over an explicit frame stack, like buffer->view-lines' own DFS —
;; the naive (map form->view form) recursion grew the fixed GC root stack with
;; nesting depth (256 slots on the device) and crashed on a deeply nested form.
;; A frame is [form remaining children-acc]: the list being converted, its
;; elements still to convert, and the converted children (reversed).
(defn form->view (form)
  (if (not (pair? form))
      (cons (%node-label form) nil)
      (do
        (let result nil)
        (let stack (list (vector form form nil)))
        (while stack
          (let top (car stack))
          (let rem (vector-ref top 1))
          (if rem
              (do                                ; convert this frame's next element
                (vector-set! top 1 (cdr rem))
                (let c (car rem))
                (if (pair? c)
                    (set stack (cons (vector c c nil) stack))
                    (vector-set! top 2 (cons (cons (%node-label c) nil)
                                             (vector-ref top 2)))))
              (do                                ; frame complete -> build its node
                (let node (cons (%node-label (vector-ref top 0))
                                (reverse (vector-ref top 2))))
                (set stack (cdr stack))
                (if stack
                    (do (let parent (car stack)) ; hand the node up as a child
                        (vector-set! parent 2 (cons node (vector-ref parent 2))))
                    (set result node)))))
        result)))

;; Index path (top-level-first) from the buffer root to the focus, derived from
;; the zipper crumbs: each frame's reversed-left length is the focus's index
;; among its siblings.
(defn %loc-path (loc)
  (let path nil)
  (let cur loc)
  (while (not (at-root? cur))
    (set path (cons (length (frame-left (car (loc-crumbs cur)))) path))
    (set cur (zip-up cur)))
  path)

;; Walk a view node down an index path (into successive children) to the node
;; that corresponds to the cursor focus.
(defn %view-at-path (node path)
  (let cur node)
  (while path
    (set cur (nth (cdr cur) (car path)))   ; cdr = children
    (set path (cdr path)))
  cur)

;; (buffer->view b) -> (root . cursor)
;;   root   : a synthetic node labelled by the buffer name whose children are
;;            the top-level forms (the whole-buffer tree the host renders).
;;   cursor : the node within `root` under the cursor (by identity, for select).
(defn buffer->view (b)
  (let root (cons (buffer-name b) (map form->view (buffer-forms b))))
  (cons root (%view-at-path root (%loc-path (buffer-loc b)))))

;; (buffer-modeline b) -> the modeline string: name + a "*" when modified.
(defn buffer-modeline (b)
  (string-append (buffer-name b) (if (buffer-modified? b) " *" "")))

;; (buffer-echo b) -> a cursor-context hint. While composing a literal it shows
;; the pending text with a caret; otherwise the focus kind and its depth ("list"
;; for a pair, else the type-of keyword, e.g. :symbol / :number).
(defn buffer-echo (b)
  (if (buffer-in-literal? b)
      (string-append "literal: " (buffer-literal-text b) "_")
      (do
        (let focus (buffer-focus b))
        (let kind (if (pair? focus) ":list" (repr (type-of focus))))
        (string-append kind " @ depth "
                       (number->string (length (loc-crumbs (buffer-loc b))))))))

;; (completion-signature token) -> "token (params)" | nil
;;   Lifted from nemacs/signature-for: when `token` names a symbol bound in this
;;   context to a Lisp fn, show its arglist via fn-params; nil for an unbound
;;   name or a C builtin (fn-params returns nil for those).
(defn completion-signature (token)
  (let sym (string->symbol token))
  (if (not (bound? sym))
      nil
      (do
        (let params (fn-params (eval sym)))
        (if params (string-append token " " (repr params)) nil))))

;; (buffer->view-lines b) -> a flat list of line records, pre-order, for a host
;; that paints a line-oriented structural view (SEAM S4 "structural spans: indent
;; depth, highlight"). Each record is (depth label cursor?). Iterative DFS over an
;; explicit stack — GC-stack-safe on a deep tree.
(defn view-line-depth (rec) (nth rec 0))
(defn view-line-label (rec) (nth rec 1))
(defn view-line-cursor? (rec) (nth rec 2))

(defn buffer->view-lines (b)
  (let v (buffer->view b))
  (let cursor (cdr v))
  (let out nil)                                ; reversed
  (let stack (list (cons (car v) 0)))          ; (node . depth)
  (while stack
    (let top (car stack))
    (set stack (cdr stack))
    (let node (car top))
    (let depth (cdr top))
    (set out (cons (list depth (car node) (if (is node cursor) t nil)) out))
    (let kids (reverse (cdr node)))            ; push reversed so leftmost pops first
    (while kids
      (set stack (cons (cons (car kids) (+ depth 1)) stack))
      (set kids (cdr kids))))
  (reverse out))

(provide 'editor/view)
