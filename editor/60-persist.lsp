;; KEC Lisp editor tier — persist : the serialize/load pair (L7).
;;
;; Part of the editor/REPL tier (ADR-0002). The library owns ONLY the
;; (serialize, load) pair — the HOST owns the bytes (SEAM S5): serialize hands
;; back a string; load ingests one. On-disk form is plain Lisp source (a
;; consequence of using the printer), so an edited buffer is just a .lsp file.
;;
;; Load order: after 30-buffer.

;; (buffer->string b) -> the buffer serialized as printable s-expression text:
;; the top-level forms, one per line, in source order. An empty buffer -> "()".
(defn buffer->string (b)
  (let forms (buffer-forms b))
  (if (nil? forms)
      "()"
      (join (map repr forms) "\n")))

;; (buffer-serialize b cap) -> the serialized string, or 0 when it would exceed
;; `cap` bytes (overflow: the host gets the 0 sentinel and no output). The host
;; supplies the byte cap (SEAM S9); the string is NUL-terminated (host strings).
(defn buffer-serialize (b cap)
  (let s (buffer->string b))
  (if (> (string-length s) cap) 0 s))

;; (buffer-load name s) -> a fresh buffer named `name` whose root is the forms
;; parsed from `s` (the reader), cursor reset to (root, 0). Symbol identity is
;; preserved by intern-by-name (the reader re-interns). A serialize -> load
;; round-trip preserves structural shape.
(defn buffer-load (name s)
  (make-buffer name (read-all s)))

;; (buffer-reload! b s) -> replace b's root in place from text `s`, resetting the
;; cursor; clears modified and the clipboard. Returns b.
(defn buffer-reload! (b s)
  (vector-set! b 0 (buffer-from-forms (read-all s)))   ; loc <- new root, cursor (root,0)
  (vector-set! b 1 nil)                                 ; clipboard cleared
  (vector-set! b 2 nil)                                 ; modified cleared
  (vector-set! b 5 nil)                                 ; literal entry cleared
  b)

(provide 'editor/persist)
