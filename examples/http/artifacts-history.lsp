;; examples/http/artifacts-history.lsp — read live trade history from the
;; Artifacts MMO grand exchange, through a local TLS proxy.
;;
;; The endpoint is public: no token, no account. Start the proxy in one
;; terminal:
;;
;;   socat TCP4-LISTEN:8080,reuseaddr,fork OPENSSL:api.artifactsmmo.com:443,verify=1
;;
;; then run this in another:
;;
;;   kec run examples/http/artifacts-history.lsp            # copper_ore, 3 rows
;;   kec run examples/http/artifacts-history.lsp iron_ore 5
;;   KEC_HTTP_PROXY_PORT=9443 kec run examples/http/artifacts-history.lsp
;;
;; The socket goes to 127.0.0.1; the Host header names api.artifactsmmo.com, so
;; the proxy's TLS handshake and the upstream server's routing both land on the
;; real origin. Getting that backwards is the classic failure of this pattern:
;; the request reaches the server and is routed to the wrong site.

(load "examples/http/http.lsp")

(let argv (cdr (args)))                     ; (args) starts with the script path
(let item (if argv (car argv) "copper_ore"))
(let size (if (cdr argv) (car (cdr argv)) "3"))
(let port (or (getenv "KEC_HTTP_PROXY_PORT") "8080"))
(let origin "api.artifactsmmo.com")

(let url (str "http://127.0.0.1:" port
              "/grandexchange/history/" (url-encode item)
              "?size=" (url-encode size)))

(let res (try (fn () (http-get url (list (cons "Host" origin))))))

(if (error? res)
    (do
      (princ "request failed: ") (princ (error-message res)) (newline)
      (princ "is the proxy running?  socat TCP4-LISTEN:") (princ port)
      (princ ",reuseaddr,fork OPENSSL:") (princ origin) (princ ":443,verify=1")
      (newline)
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
