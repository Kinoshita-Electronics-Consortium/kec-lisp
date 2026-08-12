---
title: Networking
description: TCP sockets, the HTTP/1.1 client written in KEC Lisp, and the out-of-process TLS proxy pattern that lets a dependency-free interpreter talk to an HTTPS API.
---

Networking is eight socket primitives in C (`host/net.c`), one of which does a
TLS handshake, with every protocol above them written in Lisp: HTTP/1.1 framing and chunked
transfer decoding in `examples/http/http.lsp`, JSON in
[`core/68-json.lsp`](/kec-lisp/core-library/#core68-jsonlsp--a-json-reader-and-writer),
URL encoding alongside the client.

TLS is the one piece that cannot be written in Lisp, so it is OpenSSL, linked in
and driven by `tls-connect`. See
[ADR-0007](https://github.com/Kinoshita-Electronics-Consortium/kec-lisp/blob/main/docs/adr/ADR-0007-network-primitives-and-json.md)
for the reasoning and for what the out-of-process alternative cost.

## The primitives

All eight are `KEC_PROFILE_FULL` only, alongside the file and system
primitives, and all eight are absent on a platform without POSIX sockets. Test for them the
way any gate is tested: `(bound? 'tcp-connect)`.

| Primitive | Behavior |
|---|---|
| `(tcp-connect host port [timeout-ms])` | Resolve `host` (IPv4 or IPv6) and connect in cleartext. Returns a socket handle. Raises on failure, naming host, port, and the OS reason. |
| `(tls-connect host port [timeout-ms])` | As `tcp-connect`, then a TLS handshake with mandatory certificate verification. Returns the same kind of handle. |
| `(tcp-send handle value)` | Write the whole payload, looping on partial writes. Returns the byte count. A blob goes verbatim; anything else is stringified. |
| `(tcp-recv handle max-bytes)` | Read up to `max-bytes`. Returns a string, or `nil` at clean EOF. |
| `(tcp-close handle)` | Close. Idempotent. |
| `(tcp-listen port [backlog])` | Bind and listen on 127.0.0.1. Returns a listener handle. |
| `(tcp-accept handle [timeout-ms])` | Accept one connection. Returns a socket handle, or `nil` on timeout. |
| `(tcp-port handle)` | The local port this socket is bound to. |

Plus `(sleep seconds)`, which takes a fractional number of seconds and resumes
correctly if a signal cuts it short. An action loop waiting out a
server-supplied cooldown needs it; the alternative is a busy-wait that pins a
core.

### What the handles are

A socket handle is a typed `FE_TPTR` foreign object with its own registered
lifecycle, the same mechanism the container types use. Two consequences matter
at a call site:

- **A dropped handle does not leak a descriptor.** The type's finalizer closes
  it. `tcp-close` is still the right thing to write, and it is idempotent, so a
  cleanup path can always call it.
- **A handle is invalid across an arena reset.** Never stash one expecting it to
  outlive the interpreter context.

### Timeouts

`timeout-ms` on `tcp-connect` bounds the handshake **and** becomes the socket's
read/write deadline, so a peer that accepts a connection and then goes silent
cannot wedge a script. `tcp-accept` works the same way, and the socket it
returns inherits the deadline. When a read deadline expires, `tcp-recv` raises
rather than returning `nil`: a stall must never be mistaken for end-of-stream.

### Binary data

High bytes survive `tcp-recv` intact, so UTF-8 text round-trips. An embedded
`NUL` does not, because KEC strings are NUL-terminated, so the receive contract
is capped at text. The send direction has no such limit: a blob is written
verbatim, matching `write-file`.

For a protocol whose payload may be binary, frame with the protocol's own
length header (`Content-Length`, chunk sizes) rather than reading to EOF, and
treat a `NUL` in the payload as out of scope for the string type.

## TLS runs in process

`https://` works with no proxy and no configuration:

```lisp
(load "examples/http/http.lsp")
(let res (http-get "https://api.artifactsmmo.com/grandexchange/history/copper_ore?size=3" nil))
(json-parse (http-body res))
```

`tls-connect` does the handshake and returns an ordinary socket handle, so
`tcp-send`, `tcp-recv`, and `tcp-close` drive an encrypted connection and a
cleartext one identically. Protocol code written against the plaintext
primitives runs over TLS with no edit, which is why the HTTP client needed one
line changed to gain `https://` support.

```lisp
(let c (tls-connect "api.artifactsmmo.com" 443 8000))
(tcp-send c "GET / HTTP/1.1\r\nHost: api.artifactsmmo.com\r\nConnection: close\r\n\r\n")
(tcp-recv c 4096)
(tcp-close c)
```

### Verification is mandatory

Every `tls-connect` verifies the peer certificate before the handshake
completes, and there is no flag to skip it. Two checks run:

1. **Chain.** The certificate must chain to a trusted root
   (`SSL_VERIFY_PEER`).
2. **Identity.** The name (or IP) being connected to must appear in the
   certificate. A name goes through `X509_VERIFY_PARAM_set1_host`, a literal
   address through `X509_VERIFY_PARAM_set1_ip_asc`.

A failure raises, and names the reason:

```
tls-connect: wrong.host.example:443: certificate rejected: hostname mismatch
tls-connect: 127.0.0.1:57077: certificate rejected: self-signed certificate
```

Two hardening flags are set on the identity check:

- **`NEVER_CHECK_SUBJECT`.** Without it, OpenSSL falls back to matching the
  certificate's CN whenever the certificate carries no `dNSName` SAN. A CN is
  free-form text, so that fallback lets a certificate satisfy a name it was
  never issued for. Browsers dropped it years ago. Every publicly-issued
  certificate has carried DNS SANs for a long time, so the strictness costs
  nothing in practice. A hand-rolled internal certificate with only a CN will
  be refused, and the fix is to reissue it with a SAN.
- **`NO_PARTIAL_WILDCARDS`.** Refuses `w*.example.com` while still accepting an
  ordinary leading `*.` label.

TLS 1.0 and 1.1 are refused (`SSL_CTX_set_min_proto_version(TLS1_2_VERSION)`),
so a peer cannot negotiate a withdrawn protocol version.

### Trust roots

Roots come from OpenSSL's compiled-in default paths. Two environment variables
override them, which is how to point at a private CA or a test certificate:

| Variable | Meaning |
|---|---|
| `SSL_CERT_FILE` | a single PEM bundle |
| `SSL_CERT_DIR` | a hashed directory of certificates |

```sh
SSL_CERT_FILE=/path/to/private-ca.pem kec run my-script.lsp
```

If OpenSSL has no usable store at all, `tls-connect` raises
`no trusted CA store (set SSL_CERT_FILE)` rather than connecting unverified.

### What this does not do

Client certificates, session resumption, ALPN, HTTP/2, and pinning are absent.
Server-side TLS is absent too: `tcp-listen` and `tcp-accept` are cleartext, and
their purpose is to let the suite drive both ends of an exchange.

One `SSL_CTX` is built per connection, so the CA bundle is re-read on each
`tls-connect`. That is a few milliseconds against a handshake that costs more,
and it keeps the context's lifetime tied to the handle rather than to a process
global. A connection-heavy workload that cares would want a reusable context
primitive, which does not exist yet.

### Terminating TLS out of process instead

The earlier approach, kept here because it still works and needs no OpenSSL: run
`stunnel` or `socat` (one or the other, never both) on loopback and speak
cleartext to it.

```sh
socat TCP4-LISTEN:8080,reuseaddr,fork OPENSSL:api.artifactsmmo.com:443,verify=1
```

```
[artifacts]
client = yes
accept = 127.0.0.1:8080
connect = api.artifactsmmo.com:443
verifyChain = yes
CAfile = /etc/ssl/cert.pem      ; macOS. Debian/Ubuntu: CApath = /etc/ssl/certs
checkHost = api.artifactsmmo.com
```

On macOS `/etc/ssl/certs` exists but is **empty**, so a `CApath` pointing there
verifies against nothing while looking configured; the bundle is
`/etc/ssl/cert.pem`.

Going through a proxy puts weight on the `Host` header that direct TLS does not,
which is the next section.

### The `Host` header, when using a proxy

Direct `https://` sets `Host` from the URL, so there is nothing to get wrong.
Through a proxy the socket goes to `127.0.0.1` while the request must still name
the **origin**, or the upstream server routes it to the wrong site (and on a
multi-tenant host, to somebody else's site entirely). Pass the origin
explicitly:

```lisp
(load "examples/http/http.lsp")

(let res (http-get "http://127.0.0.1:8080/grandexchange/history/copper_ore?size=3"
                   '(("Host" . "api.artifactsmmo.com"))))
(let doc (json-parse (http-body res)))
(for-each
  (fn (row)
    (princ (str (hash-ref row "seller") " -> " (hash-ref row "buyer")
                "  " (hash-ref row "quantity") " @ " (hash-ref row "price")))
    (newline))
  (hash-ref doc "data"))
```

A caller-supplied `Host` header always wins. Without one, the client derives it
from the URL, which through a proxy would be `127.0.0.1`.

`https://` URLs no longer need any of this. The proxy path remains for a build
without OpenSSL, or for an environment where the TLS policy belongs to a
supervised process rather than to the script.

### The limits of the pattern

What it provides: a verified TLS session to the origin, with the cleartext leg
confined to the loopback interface. What it leaves out: TLS inside the
interpreter, per-request SNI, client certificates, and anything else that needs
the handshake to be visible to Lisp. Anything on the loopback leg is readable by
another process on the same machine with the right privileges. On the KN-86
device, where the runtime vendors this repo, the same rule holds: TLS belongs to
the system image.

## The HTTP client

`examples/http/http.lsp` is a loadable module, deliberately outside Core. Core is
the language standard library and ships into the firmware; an HTTP client is an
application.

| Function | Purpose |
|---|---|
| `(http-request method url headers body)` | The general form. Returns a plist. |
| `(http-get url headers)` | `http-request` with `"GET"` and no body. |
| `(http-post url headers body)` | `http-request` with `"POST"`. |
| `(url-encode s)` | Percent-encode everything outside the RFC 3986 unreserved set. |
| `(url-parse url)` | `(:scheme s :host h :port n :path p)` from an `http://` URL. |
| `(http-header res name)` | One response header, looked up case-insensitively. |
| `(http-status res)` / `(http-reason res)` / `(http-headers res)` / `(http-body res)` | Read a field out of a response. |
| `(plist-get plist key)` | The general plist accessor the four above are built on. |

`headers` is an alist of `(name . value)`. The response is a plist:

```lisp
(:status 200 :reason "OK" :headers (("content-type" . "application/json") ...) :body "...")
```

Prefer the named accessors over reaching into the plist directly. A keyword is
an ordinary symbol in KEC Lisp, so an unquoted `(plist-get res :body)` reads
`:body` as an unbound variable, evaluates it to `nil`, and looks up the wrong
key without complaining. `(plist-get res ':body)` works; `(http-body res)` is
harder to get wrong.

**The status is a number**, so a caller branches on it arithmetically. The
Artifacts MMO cooldown error is HTTP 499, and `(is (http-status res) 499)`
should not be a string comparison.

### Errors versus data

A transport failure raises: a refused connection, a DNS failure, a truncated
response, a malformed status line. An HTTP error status does not. A 404 comes
back as an ordinary result with a `:status` of 404 and whatever body the server
sent, because that is data the caller wants.

### Framing

Responses are read by `Content-Length`, by `Transfer-Encoding: chunked`, or to
EOF when a server frames with neither. Chunked matters: real servers use it for
anything they generate on the fly, and a client that ignored it would return a
body truncated at an arbitrary point with no error at all.

Every request sends `Connection: close`, which is what makes read-to-EOF safe.

### Scope

Not implemented, by choice: redirects (a 3xx comes back as data, so a caller follows it), keep-alive, HEAD (its headers promise a body that never arrives),
cookies, multipart, and compression. No `Accept-Encoding` is sent, so servers
reply with identity encoding.

`Content-Length` values at or past 2²⁴ raise. A single-precision number cannot
hold them exactly, and a body framed by an inexact length would be off by a few
bytes; the practical ceiling is just under 16 MiB.

## A runnable example

`examples/http/artifacts-history.lsp` reads live trade history from the
Artifacts MMO grand exchange. The endpoint is public, so it needs no token and
no account. Start the proxy in one terminal:

```sh
socat TCP4-LISTEN:8080,reuseaddr,fork OPENSSL:api.artifactsmmo.com:443,verify=1
```

and run it in another:

```sh
kec run examples/http/artifacts-history.lsp            # copper_ore, 3 rows
kec run examples/http/artifacts-history.lsp iron_ore 5
```

Real output, against the live API through `socat`:

```
grand exchange history: copper_ore
Wuisch                     -> partypooper                    22 @      2   2026-08-07T14:58:46.432Z
Wuisch                     -> partypooper                    40 @      2   2026-08-07T15:25:55.821Z
Wuisch                     -> partypooper                    47 @      2   2026-08-07T21:36:30.031Z
```

Each row's `order_id` comes back as `"6a75cffcf2928a45b1993f68"` and stays a
string. `string->number` on it would silently yield `6`, which is why
`json-parse` never coerces one.

## Testing without a network

The conformance suite never touches the outside network. `tcp-listen` exists so
both peers of an exchange can live inside the test:

- `tests/core/net.lsp` drives a loopback client and server in one process. A
  client `connect` completes as soon as the kernel queues it on the listener's
  backlog, before `accept` runs, so a single thread can hold both ends as long
  as payloads stay inside the socket buffers.
- No test hard-codes a port. `(tcp-listen 0)` takes an ephemeral one and
  `tcp-port` reads it back, so a busy machine cannot make the suite flake.
- `tests/examples/http.lsp` serves canned `Content-Length` and chunked
  responses to the real client.
- `tests/cli/http-e2e.sh` runs the fully-composed `http-request` path against a
  second `kec` process, which is the one thing a single thread cannot express
  (`http-request` blocks in the read).
- `tests/cli/tls-verify.sh` proves the certificate contract against a throwaway
  self-signed certificate on loopback: refused while untrusted, accepted once
  `SSL_CERT_FILE` trusts it, and refused again for a name it does not cover.
  Public bad-certificate services rate-limit, which makes them useless as a
  gate.
- `tests/c/test_net.c` covers the two seams Lisp cannot reach: that a
  `SANDBOX` context has no socket primitives at all, and that the finalizer
  closes a dropped handle's descriptor.
