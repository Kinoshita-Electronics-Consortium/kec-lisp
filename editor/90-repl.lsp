;; KEC Lisp editor tier — repl : the read-eval-print loop engine (L6).
;;
;; Part of the editor/REPL tier (ADR-0002). The onboard REPL loop, host-agnostic:
;;   READ  — input is a well-formed s-expression composed with the structural
;;           editor primitives; the host submits the form (SEAM S2/S3).
;;   EVAL  — against the host-supplied context (SEAM S1): the eval-fn the host
;;           bound, under a non-propagating error handler so a failing form keeps
;;           the loop alive (L6.5).
;;   PRINT — the printer renders the result through `repl-format` into a history
;;           entry: opaque values get type tags, numbers a canonical form, and a
;;           result wider than the host width is structurally broken over lines.
;; Plus the in-memory history ring (L6.4: drop-empty, coalesce-consecutive-dup,
;; saturate-and-evict-oldest) + its walking semantics, and a guided-prompt
;; (tutorial) runner mechanism (L6.7; content + first-boot trigger are DEVICE).
;;
;; Requires `eval` (the FULL/editor tier). Load order: after 50-keymap.

;; ----- history entries --------------------------------------------------
(defn make-repl-entry (input output ok) (list input output ok))
(defn entry-input (e) (nth e 0))
(defn entry-output (e) (nth e 1))
(defn entry-ok? (e) (nth e 2))

;; ----- repl record: [history cap width eval-fn walk] --------------------
;; history : list of entries, most-recent first (the ring)
;; walk    : current history-walk index (0 = most recent) or nil (at the prompt)
(defn make-repl (capacity width eval-fn)
  (vector nil capacity width (if (nil? eval-fn) eval eval-fn) nil))

(defn repl-history (r) (vector-ref r 0))
(defn repl-capacity (r) (vector-ref r 1))
(defn repl-width (r) (vector-ref r 2))
(defn repl-eval-fn (r) (vector-ref r 3))
(defn repl-walk (r) (vector-ref r 4))
(defn repl-count (r) (length (repl-history r)))

;; ----- output formatting (the structural pretty-printer, L6.3) ----------
(defn %opaque? (v)
  (let tp (type-of v))
  (or (is tp ':fn) (is tp ':cfunc) (is tp ':macro) (is tp ':prim) (is tp ':ptr)))

(defn %type-name (v)
  (let s (symbol->string (type-of v)))   ; ":fn"
  (substring s 1 (string-length s)))      ; "fn"

;; one-line rendering: opaque values as a #<type> tag, everything else via the
;; printer (canonical numbers, quoted strings).
(defn %display1 (v)
  (if (%opaque? v) (string-append "#<" (%type-name v) ">") (repr v)))

(defn %repl-truncate (s n)
  (if (<= (string-length s) n) s (string-append (substring s 0 (- n 3)) "...")))

;; ----- structural pretty-printer (L6.3) ---------------------------------
;; A value wider than the host width is broken across lines with nested
;; structure INDENTED by depth; a sub-form that fits on its line stays inline.
;; Recursion is depth-capped (deeper structure prints flat-truncated) so it is
;; GC-stack-safe on the device; the whole result honors a line budget.
(define PP-MAX-DEPTH 8)
(define PP-LINE-BUDGET 40)

(defn %pp-append-last (lines suffix)            ; ")" onto the final line
  (let r (reverse lines))
  (reverse (cons (string-append (car r) suffix) (cdr r))))

;; (%pp value indent width depth) -> a list of fully-indented line strings.
(defn %pp (value indent width depth)
  (let flat (%display1 value))
  (if (or (<= (+ indent (string-length flat)) width)   ; fits on its line
          (not (pair? value))                          ; atom / opaque
          (>= depth PP-MAX-DEPTH))                      ; depth cap
      (list (string-append (string-repeat " " indent)
                           (%repl-truncate flat (- width indent))))
      (%pp-break value indent width depth)))

;; break a list: children pretty-printed at indent+1, with "(" tucked onto the
;; first child's first line and ")" appended to the last child's last line.
;; An improper (dotted) tail renders as its own ". tail" line.
(defn %pp-break (lst indent width depth)
  (let out nil)                                  ; reversed accumulated lines
  (let cur lst)
  (while (pair? cur)
    (let cl (%pp (car cur) (+ indent 1) width (+ depth 1)))
    (while cl (set out (cons (car cl) out)) (set cl (cdr cl)))
    (set cur (cdr cur)))
  (if cur                                        ; dotted tail (non-nil atom)
      (set out (cons (string-append (string-repeat " " (+ indent 1)) ". "
                                    (%repl-truncate (%display1 cur)
                                                    (max 4 (- width indent 3))))
                     out)))
  (let lines (reverse out))
  (let head (car lines))                         ; at indent+1; retuck "(" at indent
  (let head2 (string-append (string-repeat " " indent) "("
                            (substring head (+ indent 1) (string-length head))))
  (%pp-append-last (cons head2 (cdr lines)) ")"))

;; (repl-format r value) -> the printed result. One line when it fits the width,
;; otherwise an indented structural break, clipped to the line budget.
(defn repl-format (r value)
  (let lines (%pp value 0 (repl-width r) 0))
  (if (<= (length lines) PP-LINE-BUDGET)
      (join lines "\n")
      (string-append (join (take lines PP-LINE-BUDGET) "\n")
                     "\n... (" (number->string (- (length lines) PP-LINE-BUDGET))
                     " more lines)")))

;; ----- history ring (L6.4) ----------------------------------------------
(defn %repl-push! (r entry)
  (let hist (repl-history r))
  (if (and hist (equal? (entry-input (car hist)) (entry-input entry)))
      r                                                   ; coalesce consecutive dup
      (do
        (vector-set! r 0 (take (cons entry hist) (repl-capacity r)))  ; evict oldest
        r)))

;; ----- read-eval-print (L6.1-6.3, 6.5) ----------------------------------
;; input is a well-formed form (or nil for an empty submission). Returns
;; (entry . r): the entry the host echoes (nil when the submission was empty),
;; and the repl. Eval runs under `try`, so a failing form does NOT propagate out
;; of the loop — it lands a failed entry that preserves the input for retry.
(defn repl-submit (r input)
  (vector-set! r 4 nil)                                   ; leave history-walk
  (if (nil? input)
      (cons nil r)                                        ; empty -> drop
      (do
        (let ev (repl-eval-fn r))
        (let res (try (fn () (ev input))))
        ;; formatting a *successful* result runs under try too — a value the
        ;; pretty-printer chokes on must land a failed entry, not kill the loop
        (let entry (if (error? res)
                       (make-repl-entry input (string-append "error: " (error-message res)) nil)
                       (do
                         (let txt (try (fn () (repl-format r res))))
                         (if (error? txt)
                             (make-repl-entry input (string-append "print-error: " (error-message txt)) nil)
                             (make-repl-entry input txt t)))))
        (%repl-push! r entry)
        (cons entry r))))

;; ----- history walking (L6.4: :repl-history mode) -----------------------
(defn repl-recall (r)
  (let w (repl-walk r))
  (if (nil? w) nil (nth (repl-history r) w)))

(defn repl-older! (r)                                     ; CDR -> older
  (let n (repl-count r))
  (if (is n 0)
      r
      (do
        (let w (repl-walk r))
        (vector-set! r 4 (if (nil? w) 0 (min (- n 1) (+ w 1))))
        r)))

(defn repl-newer! (r)                                     ; reverse -> newer
  (let w (repl-walk r))
  (if (nil? w)
      r
      (do
        (if (is w 0) (vector-set! r 4 nil) (vector-set! r 4 (- w 1)))
        r)))

(defn repl-reeval! (r)                                    ; EVAL -> re-execute
  (let e (repl-recall r))
  (if (nil? e) (cons nil r) (repl-submit r (entry-input e))))

;; ----- guided-prompt (tutorial) runner mechanism (L6.7) -----------------
;; Run scripted (input . expected) pairs WITHOUT consuming history slots; return
;; a list of (input pass?). The walkthrough content + first-boot trigger are
;; DEVICE; this is only the mechanism.
(defn repl-run-guided (r prompts)
  (let ev (repl-eval-fn r))
  (map (fn (p)
         (let res (try (fn () (ev (car p)))))
         (list (car p) (and (not (error? res)) (equal? res (cdr p)))))
       prompts))

;; ----- default :repl-history keymap (L2.6 / L6.4) -----------------------
;; Walking the history ring: CDR advances to older entries, QUOTE reverses to
;; newer, EVAL re-executes the recalled entry. Handlers take and return the repl.
;; (The :repl-prompt keymap is host-wired — submitting needs the prompt buffer's
;; composed form, which the host supplies.)
(define *repl-history-keymap* (make-keymap))
(define-key *repl-history-keymap* 'CDR   (fn (r) (repl-older! r)))
(define-key *repl-history-keymap* 'QUOTE (fn (r) (repl-newer! r)))
(define-key *repl-history-keymap* 'EVAL  (fn (r) (do (repl-reeval! r) r)))
(register-keymap MODE-REPL-HISTORY *repl-history-keymap*)

(provide 'editor/repl)
