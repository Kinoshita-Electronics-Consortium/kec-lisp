;; KEC Lisp editor tier — ranker : the static token-prediction ranker (L5).
;;
;; Part of the editor/REPL tier (ADR-0002). A STATIC, DETERMINISTIC ranker (no
;; ML) returning the top-8 candidate tokens for the current edit position. One
;; ranker drives both REPL prompt completion and the nEmacs palette (L5.7). A
;; latency spike measured ~1.7 ms/call on desktop (hash-backed index, bounded
;; top-8 — no full sort), comfortably interactive on the device since it
;; recomputes only on cursor-move / insert, not per frame.
;;
;; Iterative throughout (device GC stack is 256). Hash tables (ADR-0003) back the
;; vocabulary / popularity / builtins / recency indexes — the lookups are the hot
;; path. The host feeds vocabulary + grammar via the index builder (SEAM S8).
;;
;; Adopted from the validated latency-spike prototype. Load order: after Core
;; (no buffer/zipper dependency).

;; ---------- string ordering (no built-in string<) ----------
;; Lexicographic by char code; t if a < b (shorter is "less" on a prefix tie).
(defn string-less? (a b)
  (let la (string-length a))
  (let lb (string-length b))
  (let n (if (< la lb) la lb))
  (let i 0)
  (let res nil)
  (let done nil)
  (while (and (not done) (< i n))
    (let ca (string-ref a i))
    (let cb (string-ref b i))
    (cond
      ((< ca cb) (do (set res t)   (set done t)))
      ((< cb ca) (do (set res nil) (set done t)))
      (else (set i (+ i 1)))))
  (if done res (< la lb)))

;; ---------- legal-form filter ----------
;; position-type -> the legal candidate categories. A candidate is eligible only
;; when its category is legal at this position.
;;   function pos: special forms + functions (the call head)
;;   argument pos: functions-as-values + values + bindings
;;   binding  pos: nothing from vocab (fresh names only)
;;   root     pos: special forms + functions
(defn legal-categories (pos)
  (cond
    ((is pos 'function) (list 'special 'function))
    ((is pos 'argument) (list 'function 'value 'binding))
    ((is pos 'binding)  (list 'binding))
    ((is pos 'root)     (list 'special 'function))
    (else (list 'function 'value 'binding))))

(defn category-legal? (cat legal)
  (if (member cat legal) t nil))

;; ---------- recency: exponential-ish decay over session history ----------
;; A decay vector (10 * 0.9^i) is precomputed once at load so the hot loop has
;; no pow. build-recency maps token -> best (nearest-occurrence) decay score.
(let *recency-window* 24)
(let *decay-vec* (make-vector *recency-window* 0))
(dotimes (i *recency-window*)
  (let d 10)
  (let j 0)
  (while (< j i) (set d (* d 0.9)) (set j (+ j 1)))
  (vector-set! *decay-vec* i d))

(defn build-recency (history)
  (let h (make-hash-table))
  (let i 0)
  (let cur history)
  (while (and cur (< i *recency-window*))
    (let tok (car cur))
    (let s (vector-ref *decay-vec* i))
    (let prev (hash-ref h tok -1))
    (if (< prev s) (hash-set! h tok s) nil)   ; nearest occurrence wins
    (set cur (cdr cur))
    (set i (+ i 1)))
  h)

;; ---------- scoring ----------
;; domain-vocabulary +5 ; local-binding +3 ; recency 0-10 ; popularity 0-4 ;
;; semantic-fit +1.
(defn score-token (name cat vocab-set pop-hash recency-hash local-set semfit-set)
  (let s 0)
  (if (hash-has? vocab-set name) (set s (+ s 5)) nil)
  (if (hash-has? local-set name) (set s (+ s 3)) nil)
  (set s (+ s (hash-ref recency-hash name 0)))
  (set s (+ s (hash-ref pop-hash name 0)))
  (if (hash-has? semfit-set name) (set s (+ s 1)) nil)
  s)

;; ---------- bounded top-8 insertion (no full sort) ----------
;; Higher score first; alphabetic tiebreak on equal score.
(defn better? (sa na sb nb)
  (cond
    ((< sb sa) t)
    ((< sa sb) nil)
    (else (string-less? na nb))))

;; lst is a list of (score . name) kept best-first, length <= cap.
(defn topn-insert (lst score name cap)
  (let out nil)
  (let inserted nil)
  (let cur lst)
  (while cur
    (let head (car cur))
    (if (and (not inserted) (better? score name (car head) (cdr head)))
        (do (set out (cons (cons score name) out)) (set inserted t))
        nil)
    (set out (cons head out))
    (set cur (cdr cur)))
  (if (not inserted) (set out (cons (cons score name) out)) nil)
  (take (reverse out) cap))

;; ---------- index (precomputed once; SEAM S8 host feeds vocab/pop/builtins) --
;; vocab-names : list of domain-vocabulary token strings
;; pop-alist   : alist (name . popularity 0-4)
;; builtin-names : token strings that must NEVER be suggested (no shadowing)
;; -> an idx alist of hash tables, fed to `rank`.
(defn ranker-index (vocab-names pop-alist builtin-names)
  (let vocab (make-hash-table))
  (for-each (fn (n) (hash-set! vocab n t)) vocab-names)
  (let pop (make-hash-table))
  (for-each (fn (kv) (hash-set! pop (car kv) (cdr kv))) pop-alist)
  (let builtins (make-hash-table))
  (for-each (fn (n) (hash-set! builtins n t)) builtin-names)
  (list (cons 'vocab vocab) (cons 'pop pop) (cons 'builtins builtins)))

(defn %set-from-list (names)
  (let h (make-hash-table))
  (for-each (fn (n) (hash-set! h n t)) names)
  h)

;; (ranker-context pos history locals semfit) -> a per-call ctx alist.
;; history: recent token strings, most-recent first. locals/semfit: name lists.
(defn ranker-context (pos history locals semfit)
  (list (cons 'pos pos) (cons 'history history)
        (cons 'locals (%set-from-list locals))
        (cons 'semfit (%set-from-list semfit))))

;; ---------- the ranker ----------
;; candidates: list of (name . category) static vocabulary records.
;; -> list of (score . name), best-first, length <= 8. Builtins are filtered
;; out (never shadow a builtin); only legal-position categories survive.
(defn rank (candidates ctx idx)
  (let legal (legal-categories (get 'pos ctx)))
  (let recency (build-recency (get 'history ctx)))
  (let local-set (get 'locals ctx))
  (let semfit (get 'semfit ctx))
  (let vocab (get 'vocab idx))
  (let pop (get 'pop idx))
  (let builtins (get 'builtins idx))
  (let top nil)
  (let cur candidates)
  (while cur
    (let rec (car cur))
    (let name (car rec))
    (let cat (cdr rec))
    (if (and (category-legal? cat legal)
             (not (hash-has? builtins name)))
        (do
          (let s (score-token name cat vocab pop recency local-set semfit))
          (set top (topn-insert top s name 8)))
        nil)
    (set cur (cdr cur)))
  top)

;; (rank-tokens candidates ctx idx) -> just the names, best-first (the palette /
;; completion list both the REPL prompt and the nEmacs popup render).
(defn rank-tokens (candidates ctx idx)
  (map cdr (rank candidates ctx idx)))

(provide 'editor/ranker)
