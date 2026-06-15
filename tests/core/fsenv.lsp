;; KEC Lisp — filesystem / env introspection conformance (GWP-530).
;;
;; file-exists? / list-dir / getenv are FULL-profile only. These run under
;; `kec test` (a FULL context). They create scratch files with spit (GWP-529)
;; and inspect the current directory.

(deftest "fsenv/file-exists?"
  (let path "kec-fsenv-exists.tmp")
  (spit path "x")
  (check (file-exists? path))                 ; truthy after creation
  (check (nil? (file-exists? "kec-no-such-file-xyzzy.tmp"))))

(deftest "fsenv/list-dir"
  (let marker "kec-fsenv-marker.tmp")
  (spit marker "x")
  (let entries (list-dir "."))
  (check (pair? entries))                      ; non-empty list
  ;; The marker file we just wrote must show up.
  (check (member marker entries))
  ;; "." and ".." are excluded.
  (check (nil? (member "." entries)))
  (check (nil? (member ".." entries))))

(deftest "fsenv/list-dir-missing"
  ;; Listing a path that doesn't exist raises a catchable error.
  (check-err (list-dir "kec-no-such-dir-xyzzy")))

(deftest "fsenv/getenv"
  ;; An unset variable returns nil; a set one returns a string.
  (check (nil? (getenv "KEC_DEFINITELY_UNSET_XYZZY")))
  (let p (getenv "PATH"))
  ;; PATH is set in every shell the suite runs under; if somehow absent,
  ;; tolerate nil but never a non-string.
  (check (or (nil? p) (string? p))))
