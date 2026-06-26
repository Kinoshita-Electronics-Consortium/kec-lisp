;; KEC Lisp editor tier — minibuffer : completing-read + command-by-name (M-x).
;;
;; Part of the editor/REPL tier (ADR-0002), promoted toward the application engine
;; (kn-86 ADR-0046 Decision 2: "the minibuffer / completion / command-by-name
;; surface"). This is the shared M-x fabric every program-as-mode leans on — the
;; 34-key device's discoverability lifeline solved ONCE on the engine, not N times.
;;
;; Three pieces, all headless (no display dependency — pure data, runs under
;; `kec test`):
;;   - a COMMAND registry  (string-name -> fn) and command-by-name execution;
;;   - COMPLETING-READ, ido-style incremental narrowing over a candidate list:
;;     prefix matches first, then substring matches, each group alphabetical;
;;   - a small MINIBUFFER state record [prompt input candidates] mirroring the
;;     editor's other vector records (the prompt buffer, the lifecycle record).
;;
;; Ordering reuses 80-ranker's `string-less?` (no built-in string<). Match tests
;; reuse Core's `string-prefix?` / `string-contains?` (65-strtool). Everything is
;; iterative (device GC stack is 256) — no deep recursion over candidate lists.
;;
;; Load order: after 80-ranker (string-less?), before 90-repl.

;; ----- command registry: name-string -> fn ------------------------------
(define *commands* (make-hash-table))

;; (define-command name fn) -> name. Register a named command (the M-x target).
(defn define-command (name fn) (hash-set! *commands* name fn) name)

;; (command name) -> the registered fn, or nil.
(defn command (name) (hash-ref *commands* name))

;; (command? name) -> t if name is a registered command, else nil.
(defn command? (name) (if (hash-has? *commands* name) t nil))

;; (command-names) -> the list of registered command name strings.
(defn command-names () (hash-keys *commands*))

;; ----- completing-read: ido-style incremental narrowing -----------------
;; (completing-read candidates query) -> the matching name strings, ordered
;; PREFIX matches first then SUBSTRING matches, each group alphabetical (by
;; string-less?). Empty / nil query returns ALL candidates in their given order.
;; Deterministic; iterative.
(defn completing-read (candidates query)
  (if (or (nil? query) (is query ""))
      candidates
      (do
        (let prefixes nil)      ; reversed accumulators
        (let substrings nil)
        (let cur candidates)
        (while (pair? cur)
          (let c (car cur))
          (cond
            ((string-prefix? c query)   (set prefixes (cons c prefixes)))
            ((string-contains? c query) (set substrings (cons c substrings)))
            (else nil))
          (set cur (cdr cur)))
        ;; alphabetize each group, then prefix-group ++ substring-group
        (append (sort (reverse prefixes) string-less?)
                (sort (reverse substrings) string-less?)))))

;; ----- minibuffer state: vector [prompt input candidates] ---------------
;; (make-minibuffer prompt candidates) — a fresh minibuffer with empty input.
(defn make-minibuffer (prompt candidates) (vector prompt "" candidates))

(defn minibuffer-prompt (mb) (vector-ref mb 0))
(defn minibuffer-input (mb) (vector-ref mb 1))
(defn %minibuffer-candidates (mb) (vector-ref mb 2))

;; (minibuffer-update mb input) -> mb with `input` recorded. Returns mb (mutated
;; in place, like the buffer/lifecycle records); matches recompute on demand.
(defn minibuffer-update (mb input)
  (vector-set! mb 1 input)
  mb)

;; (minibuffer-matches mb) -> the current narrowed candidate list.
(defn minibuffer-matches (mb)
  (completing-read (%minibuffer-candidates mb) (minibuffer-input mb)))

;; (minibuffer-default mb) -> the first (best) match, or nil when none match.
(defn minibuffer-default (mb)
  (let ms (minibuffer-matches mb))
  (if (pair? ms) (car ms) nil))

;; ----- command-by-name execution ----------------------------------------
;; (execute-command name . args) -> apply the named command's fn to args.
;; Raises a clear error when name is not a registered command.
(defn execute-command (name . args)
  (let fn (command name))
  (if (nil? fn)
      (error (string-append "execute-command: unknown command: " name))
      (apply fn args)))

;; (read-command query) -> completing-read over (command-names) with query: the
;; narrowed command-name list (the host picks one + calls execute-command).
(defn read-command (query) (completing-read (command-names) query))

(provide 'editor/minibuffer)
