;; examples/http/artifacts-history.lsp — read live trade history from the
;; Artifacts MMO grand exchange over HTTPS.
;;
;; The endpoint is public: no token and no account. TLS runs in process and the
;; certificate is verified on every connection.
;;
;;   kec run examples/http/artifacts-history.lsp            # copper_ore, 3 rows
;;   kec run examples/http/artifacts-history.lsp iron_ore 5

(load "examples/http/http.lsp")

(let argv (cdr (args)))                     ; (args) starts with the script path
(let item (if argv (car argv) "copper_ore"))
(let size (if (cdr argv) (car (cdr argv)) "3"))

(let url (str "https://api.artifactsmmo.com"
              "/grandexchange/history/" (url-encode item)
              "?size=" (url-encode size)))

(let res (try (fn () (http-get url nil))))

;; A transport failure raises: no route, a refused connection, or a certificate
;; that does not verify. An HTTP status never does.
(if (error? res)
    (do
      (princ "request failed: ") (princ (error-message res)) (newline)
      (exit 1))
    nil)

;; An HTTP error status is data rather than an error. Print it and stop.
(if (is (http-status res) 200)
    nil
    (do
      (princ "HTTP ") (princ (http-status res))
      (princ " ") (princ (http-reason res)) (newline)
      (princ (http-body res)) (newline)
      (exit 1)))

(let doc (json-parse (http-body res)))
(let rows (hash-ref doc "data"))

(if (nil? rows)
    (do (princ "no trade history for ") (princ item) (newline))
    (do
      (princ "grand exchange history: ") (princ item) (newline)
      (for-each
        (fn (row)
          (princ (str (pad-right (str (hash-ref row "seller")) 26)
                      " -> "
                      (pad-right (str (hash-ref row "buyer")) 26)
                      "  "
                      (pad-left (str (hash-ref row "quantity")) 5)
                      " @ "
                      (pad-left (str (hash-ref row "price")) 6)
                      "   "
                      ;; a timestamp stays a STRING: epoch arithmetic is unsafe
                      ;; at single precision, and ISO 8601 sorts lexically
                      (str (hash-ref row "sold_at"))))
          (newline))
        rows)))
