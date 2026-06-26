;; KEC Lisp editor tier — minibuffer (85-minibuffer) conformance.
;; completing-read + command-by-name (the M-x surface).
;; Loaded relative to the repo root (ctest WORKING_DIRECTORY = source dir).

(load "editor/80-ranker.lsp")
(load "editor/85-minibuffer.lsp")

;; ----- command registry -------------------------------------------------
(deftest "minibuffer/define-and-lookup"
  (check (nil? (command "save-buffer")))
  (define-command "save-buffer" (fn () 'saved))
  (check (not (nil? (command "save-buffer"))))
  (check (command? "save-buffer"))
  (check (nil? (command? "no-such-command"))))

(deftest "minibuffer/command-names"
  (define-command "alpha" (fn () 'a))
  (define-command "beta"  (fn () 'b))
  (check (member "alpha" (command-names)))
  (check (member "beta"  (command-names))))

;; ----- completing-read --------------------------------------------------
(deftest "minibuffer/completing-read-empty-returns-all"
  (let cands (list "save" "save-all" "quit"))
  (check (equal? (completing-read cands "")  cands))
  (check (equal? (completing-read cands nil) cands)))

(deftest "minibuffer/completing-read-prefix-narrows"
  (let cands (list "save" "save-all" "quit" "load"))
  (let r (completing-read cands "sa"))
  (check (member "save" r))
  (check (member "save-all" r))
  (check (nil? (member "quit" r)))
  (check (nil? (member "load" r))))

(deftest "minibuffer/completing-read-prefix-before-substring"
  ;; "ap" is a prefix of "apple" and a substring of "grape"/"map".
  (let cands (list "grape" "apple" "map"))
  (let r (completing-read cands "ap"))
  ;; prefix matches first, then substring matches; each group alphabetical
  (check (equal? r (list "apple" "grape" "map"))))

(deftest "minibuffer/completing-read-no-match-empty"
  (let cands (list "save" "quit"))
  (check (nil? (completing-read cands "zzz"))))

(deftest "minibuffer/completing-read-deterministic"
  (let cands (list "bravo" "alpha" "alfa"))
  ;; same query, same order, every call
  (check (equal? (completing-read cands "al") (completing-read cands "al")))
  (check (equal? (completing-read cands "al") (list "alfa" "alpha"))))

;; ----- minibuffer state -------------------------------------------------
(deftest "minibuffer/make-and-accessors"
  (let mb (make-minibuffer "M-x " (list "save" "quit")))
  (check (is (minibuffer-prompt mb) "M-x "))
  (check (is (minibuffer-input mb) ""))
  ;; empty input -> all candidates match
  (check (equal? (minibuffer-matches mb) (list "save" "quit"))))

(deftest "minibuffer/update-recomputes-matches"
  (let mb (make-minibuffer "M-x " (list "save" "save-all" "quit")))
  (set mb (minibuffer-update mb "sa"))
  (check (is (minibuffer-input mb) "sa"))
  (check (member "save" (minibuffer-matches mb)))
  (check (nil? (member "quit" (minibuffer-matches mb)))))

(deftest "minibuffer/default-is-first-match"
  (let mb (make-minibuffer "M-x " (list "quit" "save" "save-all")))
  (set mb (minibuffer-update mb "sa"))
  (check (is (minibuffer-default mb) "save"))
  (set mb (minibuffer-update mb "zzz"))
  (check (nil? (minibuffer-default mb))))

;; ----- execute-command --------------------------------------------------
(deftest "minibuffer/execute-runs-command"
  (define-command "echo-it" (fn (x) (cons 'echoed x)))
  (check (equal? (execute-command "echo-it" 'payload) (cons 'echoed 'payload))))

(deftest "minibuffer/execute-no-args"
  (define-command "noarg" (fn () 'ran))
  (check (is (execute-command "noarg") 'ran)))

(deftest "minibuffer/execute-unknown-raises"
  (check-err (execute-command "definitely-not-a-command")))

;; ----- read-command (end-to-end) ----------------------------------------
(deftest "minibuffer/read-command-narrows"
  (define-command "find-file"     (fn () 'ff))
  (define-command "find-grep"     (fn () 'fg))
  (define-command "save-buffer"   (fn () 'sb))
  (let r (read-command "find-"))
  (check (member "find-file" r))
  (check (member "find-grep" r))
  (check (nil? (member "save-buffer" r))))

(deftest "minibuffer/read-command-then-execute"
  (define-command "the-cmd" (fn () 'did-it))
  (let r (read-command "the-cmd"))
  (check (member "the-cmd" r))
  (check (is (execute-command (car r)) 'did-it)))
