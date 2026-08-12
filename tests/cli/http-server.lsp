;; A canned one-shot HTTP server, built from the same TCP primitives as the
;; client. Used by tests/cli/http-e2e.sh to cover the fully-composed
;; http-request path, which a single process cannot: http-request blocks in the
;; read, so the peer has to be a different process.
;;
;;   kec run tests/cli/http-server.lsp PORT
;;
;; Serves one request with a chunked body, then exits.

(let port (string->number (nth (args) 1)))
(if (nil? port) (do (princ "usage: http-server.lsp PORT") (newline) (exit 2)) nil)

(let srv (tcp-listen port))
(princ "listening") (newline)

(let con (tcp-accept srv 10000))
(if (nil? con) (do (princ "accept timed out") (newline) (exit 1)) nil)

;; Read the request head so the client's write completes before we reply.
(let req "")
(while (nil? (string-search req "\r\n\r\n"))
  (let chunk (tcp-recv con 4096))
  (if (nil? chunk) (do (princ "client closed early") (newline) (exit 1)) nil)
  (set req (str req chunk)))

;; Echo back what the client sent us, as chunked JSON: the test asserts on the
;; request line and the Host header, so the client's framing is verified from
;; the server's side of the wire too.
(let line (substring req 0 (string-search req "\r\n")))
(let host-at (string-search req "Host: "))
(let host-rest (substring req (+ host-at 6) (string-length req)))
(let host (substring host-rest 0 (string-search host-rest "\r\n")))
(let body (json-stringify (list line host)))

(tcp-send con (str "HTTP/1.1 200 OK\r\n"
                   "Content-Type: application/json\r\n"
                   "Transfer-Encoding: chunked\r\n"
                   "\r\n"))
;; Two chunks, so the client's chunked decoder has to stitch them. `floor`
;; matters: an odd body length would otherwise make a fractional chunk size,
;; which number->string refuses to render in hex.
(let half (floor (/ (string-length body) 2)))
(let a (substring body 0 half))
(let b (substring body half (string-length body)))
(tcp-send con (str (number->string (string-length a) 16) "\r\n" a "\r\n"))
(tcp-send con (str (number->string (string-length b) 16) "\r\n" b "\r\n"))
(tcp-send con "0\r\n\r\n")
(tcp-close con)
(tcp-close srv)
