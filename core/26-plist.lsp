;; KEC Core — plist : symbol property registry (get / put)
;;
;; Classic Lisp symbol properties (named get-prop / put-prop, since 25-alist
;; already owns get / put for association-list records). Fe symbols have no
;; property slot, so they live in a side registry: %plists is an alist
;; sym -> (alist key -> val). The idiomatic home for the per-symbol metadata
;; nEmacs / kec-mode want — indentation rules, a command's docstring, a
;; `disabled` flag. Symbols and keys compare by identity (assoc uses `is`).
;;
;; Loads after 25-alist; needs only `assoc` (10-list) plus kernel prims. It must
;; NOT use `nil?` / `pair?` (those load later in 30-pred), so emptiness is tested
;; with the kernel `not`.

(set %plists nil)

;; (put-prop sym key val) -> val. Store or overwrite property `key` of `sym`.
(defn put-prop (sym key val)
  (let entry (assoc sym %plists))
  (if (not entry)
      ;; sym unseen: prepend (sym . ((key . val)))
      (set %plists (cons (cons sym (list (cons key val))) %plists))
      (do
        (let kv (assoc key (cdr entry)))
        (if (not kv)
            (setcdr entry (cons (cons key val) (cdr entry)))   ; new key
            (setcdr kv val))))                                 ; overwrite
  val)

;; (get-prop sym key) -> the stored value, or nil if absent.
(defn get-prop (sym key)
  (let entry (assoc sym %plists))
  (let kv (if entry (assoc key (cdr entry)) nil))
  (if kv (cdr kv) nil))
