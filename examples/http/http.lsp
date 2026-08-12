;; examples/http/http.lsp — an HTTP/1.1 client in KEC Lisp.
;;
;; Load it and go:
;;
;;   (load "examples/http/http.lsp")
;;   (let res (http-get "http://127.0.0.1:8080/my/path"
;;                      '(("Host" . "api.example.com"))))
;;   (json-parse (http-body res))
;;
;; This is NOT part of Core. Core is the language standard library and ships
;; into the KN-86 firmware; an HTTP client is an application, so it lives here
;; as a loadable module. Everything below rides on the TCP primitives
;; (tcp-connect / tcp-send / tcp-recv / tcp-close, plus tcp-listen /
;; tcp-accept / tcp-port for the tests) and Core. Framing, chunked transfer decoding, and URL encoding are all Lisp.
;;
;; NO TLS. `https://` raises. Terminate TLS outside the process with stunnel or
;; socat and speak cleartext to the local listener:
;;
;;   stunnel artifacts.conf     (see docs/networking.md for the config)
;;   socat TCP4-LISTEN:8080,reuseaddr,fork OPENSSL:api.artifactsmmo.com:443,verify=1
;;
;; Then the URL names 127.0.0.1 while the `Host:` header names the ORIGIN, so
;; the upstream server routes and certificates match:
;;
;;   (http-get "http://127.0.0.1:8080/path" '(("Host" . "api.artifactsmmo.com")))
;;
;; A caller-supplied Host header always wins; without one the host from the URL
;; is used. See docs/networking.md and ADR-0007.
;;
;; SCOPE. GET/POST/PUT/DELETE-shaped requests with an optional string body,
;; `Content-Length` and `Transfer-Encoding: chunked` responses, and read-to-EOF
;; when a server frames with neither. Not here: redirects (the 3xx is returned
;; as data, so a caller follows it), keep-alive (every request sends
;; `Connection: close`), HEAD (its headers promise a body that never arrives),
;; cookies, multipart, compression (no `Accept-Encoding` is sent, so servers
;; reply with identity).
;;
;; ERRORS vs DATA. A transport failure raises: refused connection, DNS failure,
;; a truncated response, a malformed status line. An HTTP error status does not.
;; A 404 or a 499 comes back as an ordinary result whose :status is a NUMBER, so
;; callers branch on it arithmetically instead of matching strings.

;; --- small utilities ----------------------------------------------------

;; (plist-get plist key) — the value following key, or nil. Response objects are
;; plists (:status ... :headers ... :body ...), which read well at a call site.
(defn plist-get (plist key)
  (let val nil)
  (let found nil)
  (while (and plist (not found))
    (if (is (car plist) key)
        (do (set val (car (cdr plist))) (set found 1))
        nil)
    (set plist (cdr (cdr plist))))
  val)

;; (%http-trim s) — drop leading and trailing spaces and tabs.
(defn %http-trim (s)
  (let n (string-length s))
  (let a 0)
  (while (and (< a n) (or (is (string-ref s a) 32) (is (string-ref s a) 9)))
    (set a (+ a 1)))
  (while (and (< a n)
              (or (is (string-ref s (- n 1)) 32) (is (string-ref s (- n 1)) 9)))
    (set n (- n 1)))
  (substring s a n))

;; (%http-digits? s) — non-empty and all ASCII digits.
(defn %http-digits? (s)
  (let n (string-length s))
  (let i 0)
  (let ok (< 0 n))
  (while (and ok (< i n))
    (if (char-digit? (string-ref s i)) (set i (+ i 1)) (set ok nil)))
  ok)

;; (%http-hex s) — a hex string as a number (chunk sizes arrive in hex).
(defn %http-hex (s)
  (let n (string-length s))
  (if (is n 0) (raise "http: empty chunk size") nil)
  (let v 0)
  (let i 0)
  (while (< i n)
    (let c (string-ref s i))
    (let d (cond
             ((and (<= 48 c) (<= c 57))  (- c 48))
             ((and (<= 97 c) (<= c 102)) (- c 87))
             ((and (<= 65 c) (<= c 70))  (- c 55))
             (else (raise (str "http: bad chunk size: " s)))))
    (set v (+ (* v 16) d))
    (set i (+ i 1)))
  v)

;; (url-encode s) — percent-encode every byte outside the RFC 3986 unreserved
;; set (A-Z a-z 0-9 - _ . ~). Safe for both query values and path segments.
(defn url-encode (s)
  (let n (string-length s))
  (let out nil)
  (let i 0)
  (while (< i n)
    (let c (string-ref s i))
    (if (or (char-alphanumeric? c) (is c 45) (is c 95) (is c 46) (is c 126))
        (set out (cons (char->string c) out))
        (set out (cons (str "%" (string-upcase (pad-left (number->string c 16) 2 "0")))
                       out)))
    (set i (+ i 1)))
  (string-concat (reverse out)))

;; (url-parse url) -> (:scheme s :host h :port n :path p)
;; http:// only, by design; see the TLS note at the top. An IPv6 literal in
;; brackets is not parsed (the proxy pattern never needs one).
(defn url-parse (url)
  (if (string-prefix? url "https://")
      (raise (str "url-parse: https is not supported. Terminate TLS out of "
                  "process and request http://127.0.0.1:PORT with a Host header "
                  "naming the origin (see docs/networking.md): " url))
      nil)
  (if (not (string-prefix? url "http://"))
      (raise (str "url-parse: expected an http:// URL: " url))
      nil)
  (let rest (substring url 7 (string-length url)))
  (let slash (string-search rest "/"))
  (let authority (if slash (substring rest 0 slash) rest))
  (let path (if slash (substring rest slash (string-length rest)) "/"))
  (let colon (string-search authority ":"))
  (let host (if colon (substring authority 0 colon) authority))
  (let port-text (if colon
                     (substring authority (+ colon 1) (string-length authority))
                     "80"))
  (if (is host "") (raise (str "url-parse: no host in URL: " url)) nil)
  (if (not (%http-digits? port-text))
      (raise (str "url-parse: bad port in URL: " url))
      nil)
  (list ':scheme "http" ':host host ':port (string->number port-text) ':path path))

;; --- a buffered reader over one connection ------------------------------
;;
;; A 3-slot vector: connection, bytes read but not yet consumed, EOF flag.
;; tcp-recv returns whatever one read yields, so every framing rule below is
;; expressed as "consume this much / consume up to this marker, filling as
;; needed".

(defvar http-recv-chunk 16384)   ; bytes requested per tcp-recv
(defvar http-timeout-ms 15000)   ; connect + read/write deadline

(defn %http-reader (conn)
  (vector conn "" nil))

;; (%http-fill! r) — pull one more read into the buffer. Truthy if bytes
;; arrived, nil once the peer has closed.
(defn %http-fill! (r)
  (if (vector-ref r 2)
      nil
      (do
        (let chunk (tcp-recv (vector-ref r 0) http-recv-chunk))
        (if (nil? chunk)
            (do (vector-set! r 2 1) nil)
            (do (vector-set! r 1 (str (vector-ref r 1) chunk)) 1)))))

;; (%http-take! r k) — consume exactly k bytes. An EOF before that is a
;; truncated response, which is a transport failure, not a short body.
(defn %http-take! (r k)
  (while (< (string-length (vector-ref r 1)) k)
    (if (%http-fill! r) nil (raise "http: connection closed mid-body")))
  (let buf (vector-ref r 1))
  (let out (substring buf 0 k))
  (vector-set! r 1 (substring buf k (string-length buf)))
  out)

;; (%http-line! r) — consume through the next CRLF, returning the line without
;; it.
(defn %http-line! (r)
  (let idx (string-search (vector-ref r 1) "\r\n"))
  (while (nil? idx)
    (if (%http-fill! r) nil (raise "http: connection closed before end of line"))
    (set idx (string-search (vector-ref r 1) "\r\n")))
  (let buf (vector-ref r 1))
  (let line (substring buf 0 idx))
  (vector-set! r 1 (substring buf (+ idx 2) (string-length buf)))
  line)

;; (%http-rest! r) — everything up to EOF.
(defn %http-rest! (r)
  (while (%http-fill! r))
  (let buf (vector-ref r 1))
  (vector-set! r 1 "")
  buf)

;; --- response parsing ---------------------------------------------------

;; (http-parse-status-line line) -> (:version v :status n :reason s)
;; The status is a number so callers can branch on it. 499 is the Artifacts
;; cooldown error, and comparing it should not be a string match.
(defn http-parse-status-line (line)
  (let sp1 (string-search line " "))
  (if (nil? sp1) (raise (str "http: malformed status line: " line)) nil)
  (let rest (substring line (+ sp1 1) (string-length line)))
  (let sp2 (string-search rest " "))
  (let code-text (if sp2 (substring rest 0 sp2) rest))
  (let reason (if sp2 (substring rest (+ sp2 1) (string-length rest)) ""))
  (if (not (and (%http-digits? code-text) (is (string-length code-text) 3)))
      (raise (str "http: malformed status line: " line))
      nil)
  (list ':version (substring line 0 sp1)
        ':status (string->number code-text)
        ':reason reason))

;; (%http-read-headers! r) -> alist of (lowercased-name . value), in order.
;; Names are lowercased because HTTP field names are case-insensitive and a
;; server may capitalize them any way it likes.
(defn %http-read-headers! (r)
  (let hs nil)
  (let done nil)
  (while (not done)
    (let line (%http-line! r))
    (if (is line "")
        (set done 1)
        (do
          (let idx (string-search line ":"))
          (if (nil? idx) (raise (str "http: malformed header line: " line)) nil)
          (set hs (cons (cons (string-downcase (substring line 0 idx))
                              (%http-trim (substring line (+ idx 1)
                                                     (string-length line))))
                        hs)))))
  (reverse hs))

;; (%http-read-chunked! r) — decode Transfer-Encoding: chunked. Real servers
;; use it for anything they generate on the fly, and a client that ignores it
;; hands back a body truncated at an arbitrary point with no error.
(defn %http-read-chunked! (r)
  (let chunks nil)
  (let done nil)
  (while (not done)
    (let line (%http-line! r))
    (let semi (string-search line ";"))          ; chunk extensions are ignored
    (let size (%http-hex (%http-trim (if semi (substring line 0 semi) line))))
    (if (is size 0)
        (do
          (while (not (is (%http-line! r) "")) nil)   ; trailer section
          (set done 1))
        (do
          (set chunks (cons (%http-take! r size) chunks))
          (if (is (%http-line! r) "")
              nil
              (raise "http: chunk not terminated by CRLF")))))
  (string-concat (reverse chunks)))

;; (%http-content-length text) — a Content-Length as an exact number.
;; fe_Number is a single-precision float, so a length at or past 2^24 cannot be
;; held exactly and would mis-frame the body by a few bytes. `(is (+ n 1) n)`
;; is precisely the "this integer is no longer exact" test: it is true from
;; 16777216 up. The practical ceiling is therefore just under 16 MiB, which is
;; already a preposterous size for a response held whole in a string.
(defn %http-content-length (text)
  (if (not (%http-digits? text))
      (raise (str "http: bad Content-Length: " text))
      nil)
  (let n (string->number text))
  (if (is (+ n 1) n)
      (raise (str "http: Content-Length " text
                  " is past the exact-integer range of a KEC number"))
      nil)
  n)

;; (http-read-response conn) -> (:status n :reason s :headers alist :body s)
;; Framing order matches RFC 9112: chunked wins over Content-Length, and with
;; neither the body runs to EOF (which is why every request says
;; Connection: close). 204/304 carry no body by definition.
(defn http-read-response (conn)
  (let r (%http-reader conn))
  (let status (http-parse-status-line (%http-line! r)))
  (let hs (%http-read-headers! r))
  (let code (plist-get status ':status))
  (let te (get "transfer-encoding" hs))
  (let cl (get "content-length" hs))
  (let body
    (cond
      ((and te (string-contains? (string-downcase te) "chunked"))
       (%http-read-chunked! r))
      ((or (is code 204) (is code 304) (< code 200)) "")
      (cl (%http-take! r (%http-content-length cl)))
      (else (%http-rest! r))))
  (list ':status code
        ':reason (plist-get status ':reason)
        ':headers hs
        ':body body))

;; (http-header res name) — one response header by (case-insensitive) name.
(defn http-header (res name)
  (get (string-downcase name) (plist-get res ':headers)))

;; Named accessors, because a keyword is an ordinary symbol in this language:
;; an unquoted (plist-get res :body) reads :body as an unbound variable, which
;; evaluates to nil and silently hands plist-get the wrong key. These read
;; better than (plist-get res ':body) and cannot be mis-quoted.
(defn http-status (res) (plist-get res ':status))
(defn http-reason (res) (plist-get res ':reason))
(defn http-headers (res) (plist-get res ':headers))
(defn http-body (res) (plist-get res ':body))

;; --- request building ---------------------------------------------------

;; Headers this module owns; a caller-supplied copy would produce a duplicate
;; or contradict the framing. Host is emitted separately from the resolved
;; origin value, which may come from the caller.
(defn %http-reserved? (name)
  (let n (string-downcase name))
  (or (is n "host") (or (is n "connection") (is n "content-length"))))

;; (%http-header-value headers name) — a caller header by case-insensitive name.
(defn %http-header-value (headers name)
  (let want (string-downcase name))
  (let out nil)
  (while (and headers (nil? out))
    (if (is (string-downcase (car (car headers))) want)
        (set out (cdr (car headers)))
        nil)
    (set headers (cdr headers)))
  out)

;; (http-send-request conn method path headers body host) -> bytes written.
;; Split out from http-request so a test (or a caller managing its own socket)
;; can drive the two halves of an exchange independently.
(defn http-send-request (conn method path headers body host)
  (let out nil)
  (set out (cons (str (string-upcase method) " " path " HTTP/1.1\r\n") out))
  (set out (cons (str "Host: " host "\r\n") out))
  (set out (cons "Connection: close\r\n" out))
  (if body
      (set out (cons (str "Content-Length: " (string-length body) "\r\n") out))
      nil)
  (if (and body (nil? (%http-header-value headers "Content-Type")))
      (set out (cons "Content-Type: application/json\r\n" out))
      nil)
  (let hs headers)
  (while hs
    (let h (car hs))
    (if (%http-reserved? (car h))
        nil
        (set out (cons (str (car h) ": " (cdr h) "\r\n") out)))
    (set hs (cdr hs)))
  (set out (cons "\r\n" out))
  (if body (set out (cons body out)) nil)
  (tcp-send conn (string-concat (reverse out))))

;; (http-request method url headers body) -> the response plist.
;; `headers` is an alist of (name . value); `body` is a string or nil. The
;; connection is always closed, including on a raise.
(defn http-request (method url headers body)
  (let u (url-parse url))
  (let host (or (%http-header-value headers "Host") (plist-get u ':host)))
  (let conn (tcp-connect (plist-get u ':host) (plist-get u ':port) http-timeout-ms))
  (unwind-protect
    (do
      (http-send-request conn method (plist-get u ':path) headers body host)
      (http-read-response conn))
    (tcp-close conn)))

(defn http-get (url headers)
  (http-request "GET" url headers nil))

(defn http-post (url headers body)
  (http-request "POST" url headers body))

(provide 'http)
