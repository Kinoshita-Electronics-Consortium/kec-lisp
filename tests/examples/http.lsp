;; KEC Lisp — HTTP/1.1 client conformance (examples/http/http.lsp).
;;
;; HERMETIC. The "server" is a loopback listener built from the same TCP
;; primitives as the client, serving canned bytes. Nothing leaves the machine.
;;
;; Both peers share one thread, so the exchange is driven a half at a time:
;; http-send-request writes the request, the canned server reads it and writes
;; the response, then http-read-response parses it. That is exactly the pair
;; http-request composes, and it is the only interleaving a single thread can
;; express, since http-request blocks in the read, so the fully-composed call
;; is covered by the two-process end-to-end test (tests/cli/http-e2e.sh)
;; instead.
;;
;; Run from the repo root (the ctest entry sets the working directory).

(load "examples/http/http.lsp")

;; An ephemeral loopback port, read back with tcp-port: no hard-coded number to
;; collide with anything else on the machine.
(defn %http-test-listen ()
  (let srv (tcp-listen 0))
  (cons srv (tcp-port srv)))

;; Read from `conn` until the request head is complete, so the assertion below
;; never races a request split across TCP segments.
(defn %http-test-slurp-request (conn)
  (let buf "")
  (while (nil? (string-search buf "\r\n\r\n"))
    (let chunk (tcp-recv conn 4096))
    (if (nil? chunk) (raise "http test: client closed before sending a request") nil)
    (set buf (str buf chunk)))
  buf)

;; Drive one exchange: send `method path headers body` from the client, capture
;; the raw request the server saw, hand back `response` verbatim, and parse it.
;; Returns (raw-request . response-plist).
(defn %http-test-exchange (response method path headers body host)
  (let lp (%http-test-listen))
  (let srv (car lp))
  (let cli (tcp-connect "127.0.0.1" (cdr lp) 2000))
  (let con (tcp-accept srv 2000))
  (if (nil? con) (raise "http test: accept timed out") nil)
  (http-send-request cli method path headers body host)
  (let req (%http-test-slurp-request con))
  (tcp-send con response)
  (tcp-close con)                       ; Connection: close, so EOF ends the body
  (let res (http-read-response cli))
  (tcp-close cli)
  (tcp-close srv)
  (cons req res))

;; --- url-encode ---------------------------------------------------------

(deftest "http/url-encode"
  (check (is (url-encode "copper_ore") "copper_ore"))
  (check (is (url-encode "abcXYZ019") "abcXYZ019"))
  (check (is (url-encode "-_.~") "-_.~"))        ; the unreserved set is untouched
  (check (is (url-encode "a b") "a%20b"))
  (check (is (url-encode "a/b") "a%2Fb"))
  (check (is (url-encode "a&b=c") "a%26b%3Dc"))
  (check (is (url-encode "?#[]@") "%3F%23%5B%5D%40"))
  (check (is (url-encode "+") "%2B"))
  (check (is (url-encode "") ""))
  ;; a byte below 0x10 keeps its zero pad
  (check (is (url-encode (char->string 10)) "%0A"))
  ;; UTF-8 is encoded byte by byte (e-acute is 0xC3 0xA9)
  (check (is (url-encode (str (char->string 195) (char->string 169))) "%C3%A9")))

;; --- url-parse ----------------------------------------------------------

(deftest "http/url-parse"
  (let u (url-parse "http://127.0.0.1:8080/grandexchange/history/copper_ore?size=3"))
  (check (is (plist-get u ':scheme) "http"))
  (check (is (plist-get u ':host) "127.0.0.1"))
  (check (is (plist-get u ':port) 8080))
  (check (is (plist-get u ':path) "/grandexchange/history/copper_ore?size=3"))
  ;; the default port is 80, and a missing path is "/"
  (let d (url-parse "http://example.com"))
  (check (is (plist-get d ':port) 80))
  (check (is (plist-get d ':path) "/"))
  (let s (url-parse "http://example.com/"))
  (check (is (plist-get s ':path) "/")))

(deftest "http/url-parse-https"
  ;; https parses, defaults to 443, and flags the transport
  (let u (url-parse "https://api.artifactsmmo.com/my/characters"))
  (check (is (plist-get u ':scheme) "https"))
  (check (is (plist-get u ':host) "api.artifactsmmo.com"))
  (check (is (plist-get u ':port) 443))
  (check (is (plist-get u ':path) "/my/characters"))
  (check (plist-get u ':tls))
  ;; an explicit port still wins
  (check (is (plist-get (url-parse "https://example.com:8443/x") ':port) 8443))
  ;; and http stays cleartext on 80
  (let h (url-parse "http://example.com/x"))
  (check (is (plist-get h ':port) 80))
  (check (nil? (plist-get h ':tls))))

(deftest "http/url-parse-rejects"
  (check-err (url-parse "ftp://example.com/"))
  (check-err (url-parse "example.com/path"))     ; no scheme
  (check-err (url-parse "http:///path"))         ; no host
  (check-err (url-parse "http://example.com:80x/")))

;; --- status line and headers -------------------------------------------

(deftest "http/parse-status-line"
  (let s (http-parse-status-line "HTTP/1.1 200 OK"))
  (check (is (plist-get s ':status) 200))
  (check (number? (plist-get s ':status)))       ; a NUMBER, so callers can branch
  (check (is (plist-get s ':reason) "OK"))
  (check (is (plist-get s ':version) "HTTP/1.1"))
  ;; a multi-word reason phrase keeps its spaces
  (check (is (plist-get (http-parse-status-line "HTTP/1.1 404 Not Found") ':reason)
             "Not Found"))
  ;; an empty reason phrase is legal
  (check (is (plist-get (http-parse-status-line "HTTP/1.1 204 ") ':status) 204))
  (check (is (plist-get (http-parse-status-line "HTTP/1.0 499 Cooldown") ':status) 499)))

(deftest "http/parse-status-line-rejects"
  (check-err (http-parse-status-line ""))
  (check-err (http-parse-status-line "HTTP/1.1"))
  (check-err (http-parse-status-line "HTTP/1.1 2OO OK"))
  (check-err (http-parse-status-line "HTTP/1.1 20 OK")))

;; --- the request the client puts on the wire ----------------------------

(deftest "http/request-line-and-headers"
  (let x (%http-test-exchange
           "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"
           "GET" "/items?page=2" '(("Accept" . "application/json")) nil
           "api.artifactsmmo.com"))
  (let req (car x))
  (check (string-prefix? req "GET /items?page=2 HTTP/1.1\r\n"))
  ;; through a TLS proxy the Host header must carry the ORIGIN, not 127.0.0.1,
  ;; or the upstream server routes the request to the wrong site
  (check (string-contains? req "\r\nHost: api.artifactsmmo.com\r\n"))
  (check (string-contains? req "\r\nConnection: close\r\n"))
  (check (string-contains? req "\r\nAccept: application/json\r\n"))
  (check (string-suffix? req "\r\n\r\n"))
  ;; a GET carries no body and therefore no Content-Length
  (check (nil? (string-contains? req "Content-Length"))))

(deftest "http/post-body-framing"
  (let x (%http-test-exchange
           "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
           "POST" "/action/move" nil "{\"x\":1,\"y\":-2}" "api.example.com"))
  (let req (car x))
  (check (string-prefix? req "POST /action/move HTTP/1.1\r\n"))
  (check (string-contains? req "\r\nContent-Length: 14\r\n"))
  (check (string-contains? req "\r\nContent-Type: application/json\r\n"))
  (check (string-suffix? req "\r\n\r\n{\"x\":1,\"y\":-2}")))

(deftest "http/caller-headers-cannot-duplicate-framing"
  ;; Host comes from the resolved origin; Connection and Content-Length are
  ;; owned by the client. A caller copy of any of them is dropped, not doubled.
  (let x (%http-test-exchange
           "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
           "GET" "/" '(("Host" . "ignored.example")
                       ("Connection" . "keep-alive")
                       ("Content-Length" . "999")
                       ("X-Token" . "abc"))
           nil "real.example"))
  (let req (car x))
  (check (string-contains? req "\r\nHost: real.example\r\n"))
  (check (nil? (string-contains? req "ignored.example")))
  (check (nil? (string-contains? req "keep-alive")))
  (check (nil? (string-contains? req "999")))
  (check (string-contains? req "\r\nX-Token: abc\r\n"))
  ;; a caller-supplied Content-Type wins over the default
  (let y (%http-test-exchange
           "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
           "POST" "/" '(("Content-Type" . "text/plain")) "hello" "real.example"))
  (check (string-contains? (car y) "\r\nContent-Type: text/plain\r\n"))
  (check (nil? (string-contains? (car y) "application/json"))))

;; --- response framing ---------------------------------------------------

(deftest "http/content-length-response"
  (let x (%http-test-exchange
           (str "HTTP/1.1 200 OK\r\n"
                "Content-Type: application/json\r\n"
                "Content-Length: 27\r\n"
                "\r\n"
                "{\"data\":[{\"price\":11}]}xxxx")
           "GET" "/x" nil nil "example"))
  (let res (cdr x))
  (check (is (plist-get res ':status) 200))
  (check (is (plist-get res ':reason) "OK"))
  ;; exactly Content-Length bytes, including the trailing padding
  (check (is (string-length (plist-get res ':body)) 27))
  (check (is (plist-get res ':body) "{\"data\":[{\"price\":11}]}xxxx"))
  ;; headers are exposed lowercased, and looked up case-insensitively
  (check (is (http-header res "Content-Type") "application/json"))
  (check (is (http-header res "CONTENT-TYPE") "application/json"))
  (check (nil? (http-header res "X-Absent"))))

(deftest "http/content-length-shorter-than-the-stream"
  ;; Only Content-Length bytes are taken, even when the server sent more.
  (let x (%http-test-exchange
           "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabcdefgh"
           "GET" "/x" nil nil "example"))
  (check (is (plist-get (cdr x) ':body) "abc")))

(deftest "http/chunked-response"
  ;; Real servers chunk anything they generate on the fly; a client that
  ;; ignored this would hand back "Wiki" and drop the rest.
  (let x (%http-test-exchange
           (str "HTTP/1.1 200 OK\r\n"
                "Transfer-Encoding: chunked\r\n"
                "\r\n"
                "4\r\nWiki\r\n"
                "6\r\npedia \r\n"
                "E\r\nin \r\n\r\nchunks.\r\n"      ; uppercase hex size, CRLF inside
                "0\r\n\r\n")
           "GET" "/x" nil nil "example"))
  (let res (cdr x))
  (check (is (plist-get res ':status) 200))
  (check (is (plist-get res ':body)
             (str "Wikipedia in \r\n\r\nchunks.")))
  (check (is (string-length (plist-get res ':body)) 24)))

(deftest "http/chunked-with-extensions-and-trailers"
  (let x (%http-test-exchange
           (str "HTTP/1.1 200 OK\r\n"
                "Transfer-Encoding: chunked\r\n"
                "\r\n"
                "5;name=value\r\nhello\r\n"       ; chunk extension, ignored
                "0\r\n"
                "X-Checksum: deadbeef\r\n"        ; trailer section
                "\r\n")
           "GET" "/x" nil nil "example"))
  (check (is (plist-get (cdr x) ':body) "hello")))

(deftest "http/chunked-empty-body"
  (let x (%http-test-exchange
           "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
           "GET" "/x" nil nil "example"))
  (check (is (plist-get (cdr x) ':body) "")))

(deftest "http/read-to-eof-when-unframed"
  ;; Neither Content-Length nor chunked: the body runs to the close, which is
  ;; why every request says Connection: close.
  (let x (%http-test-exchange
           "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nno framing here"
           "GET" "/x" nil nil "example"))
  (check (is (plist-get (cdr x) ':body) "no framing here")))

(deftest "http/bodiless-statuses"
  (let x (%http-test-exchange
           "HTTP/1.1 204 No Content\r\n\r\n" "DELETE" "/x" nil nil "example"))
  (check (is (plist-get (cdr x) ':status) 204))
  (check (is (plist-get (cdr x) ':body) "")))

;; An HTTP error status is DATA rather than an error: a client must be able to
;; see a 404 body and branch on a 499 cooldown without catching anything.
(deftest "http/error-statuses-are-values"
  (let x (%http-test-exchange
           (str "HTTP/1.1 404 Not Found\r\nContent-Length: 26\r\n\r\n"
                "{\"error\":{\"code\":404}}\r\n\r\n")
           "GET" "/missing" nil nil "example"))
  (let res (cdr x))
  (check (is (plist-get res ':status) 404))
  (check (is (hash-ref (hash-ref (json-parse (%http-trim (plist-get res ':body)))
                                 "error") "code")
             404))
  ;; the Artifacts cooldown status, branched on arithmetically
  (let y (%http-test-exchange
           "HTTP/1.1 499 Character in cooldown\r\nContent-Length: 0\r\n\r\n"
           "GET" "/action" nil nil "example"))
  (check (is (plist-get (cdr y) ':status) 499))
  (check (is (plist-get (cdr y) ':reason) "Character in cooldown")))

;; --- transport failures raise ------------------------------------------

(deftest "http/truncated-response-raises"
  ;; Content-Length promises 100 bytes and the server sends 4 then closes.
  ;; Silently returning 4 bytes would be the worst outcome.
  (let r (try (fn () (%http-test-exchange
                       "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabcd"
                       "GET" "/x" nil nil "example"))))
  (check (error? r))
  (check (string-contains? (error-message r) "closed mid-body")))

(deftest "http/malformed-response-raises"
  (check-err (%http-test-exchange "GARBAGE\r\n\r\n" "GET" "/x" nil nil "example"))
  (check-err (%http-test-exchange
               "HTTP/1.1 200 OK\r\nno-colon-here\r\n\r\n" "GET" "/x" nil nil "example"))
  (check-err (%http-test-exchange
               (str "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                    "zz\r\nabc\r\n0\r\n\r\n")
               "GET" "/x" nil nil "example")))

(deftest "http/refused-connection-raises"
  ;; The whole http-request path: url-parse, connect, and a transport failure
  ;; surfacing as an error rather than a status.
  (let lp (%http-test-listen))
  (let port (cdr lp))
  (tcp-close (car lp))
  (let r (try (fn () (http-get (str "http://127.0.0.1:" port "/") nil))))
  (check (error? r))
  (check (string-prefix? (error-message r) "tcp-connect:")))

(deftest "http/content-length-past-the-exact-integer-range"
  ;; A float cannot hold an integer at or past 2^24 exactly, so the framing
  ;; would be off by a few bytes. Refuse rather than mis-frame.
  (check-err (%http-content-length "16777216"))
  (check-err (%http-content-length "99999999"))
  (check-err (%http-content-length "not-a-number"))
  (check-err (%http-content-length ""))
  (check (is (%http-content-length "16777215") 16777215))
  (check (is (%http-content-length "0") 0)))

;; A keyword is an ordinary symbol here, so an unquoted (plist-get res :body)
;; would read :body as an unbound variable, evaluate it to nil, and look up the
;; wrong key without complaining. The named accessors remove that trap.
(deftest "http/named-accessors"
  (let x (%http-test-exchange
           "HTTP/1.1 201 Created\r\nContent-Length: 2\r\nX-Trace: t1\r\n\r\nok"
           "POST" "/x" nil "b" "example"))
  (let res (cdr x))
  (check (is (http-status res) 201))
  (check (is (http-reason res) "Created"))
  (check (is (http-body res) "ok"))
  (check (is (get "x-trace" (http-headers res)) "t1"))
  ;; the quoted-keyword spelling agrees with the accessors ...
  (check (is (plist-get res ':status) (http-status res)))
  (check (is (plist-get res ':body) (http-body res)))
  ;; ... and the unquoted spelling is the trap: :body reads as nil, and no key
  ;; in the plist is nil, so the lookup misses
  (check (nil? (plist-get res :body))))
