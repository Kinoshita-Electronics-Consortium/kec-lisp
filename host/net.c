/*
** net.c — KEC Lisp's TCP socket primitives.
**
** Eight primitives (tcp-connect / tls-connect / tcp-send / tcp-recv /
** tcp-close / tcp-listen / tcp-accept / tcp-port), FULL profile only, POSIX
** sockets. Everything above the byte stream (HTTP framing, JSON, URL encoding)
** is written in KEC Lisp (core/68-json.lsp, examples/http/http.lsp).
**
** TLS is IN PROCESS, over OpenSSL (ADR-0007). tls-connect performs the
** handshake and returns the same kind of handle tcp-connect does, so
** tcp-send / tcp-recv / tcp-close drive an encrypted connection and a
** cleartext one identically. Certificates are ALWAYS verified: chain to a
** trusted root, plus a hostname (or IP) match. There is no way to turn that
** off from Lisp, because a silent downgrade is the failure mode that makes
** TLS worthless.
**
** PORTABILITY. The whole implementation is gated on <sys/socket.h> being
** present. A platform without it (a bare-metal or Windows build of the
** interpreter) compiles this file to an empty registration function: the
** primitives are simply absent, and Lisp can test for them with
** (bound? 'tcp-connect) exactly as it tests for a profile gate. Registering
** nothing is the deliberate degraded mode: a stub that always raised would be
** indistinguishable from a real network failure.
**
** C name `h_foo`  ->  KEC Lisp symbol `foo-bar` (kebab-case), as in host.c.
*/
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE /* SO_NOSIGPIPE + getaddrinfo together on macOS */
#else
#define _POSIX_C_SOURCE 200809L /* getaddrinfo / poll / nanosleep */
#endif

#include "host.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__has_include)
#if __has_include(<sys/socket.h>)
#define KEC_NET_POSIX 1
#endif
#elif defined(__unix__) || defined(__unix) || (defined(__APPLE__) && defined(__MACH__))
#define KEC_NET_POSIX 1
#endif

#ifdef KEC_NET_POSIX

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

/* SIGPIPE suppression is per-socket, never process-wide: installing a global
** SIG_IGN would change the behavior of the whole embedding program (the KN-86
** firmware, or any host linking libkec). BSD/macOS take it as a socket option
** at creation; Linux takes it as a per-send flag. */
#ifdef MSG_NOSIGNAL
#define KEC_SEND_FLAGS MSG_NOSIGNAL
#else
#define KEC_SEND_FLAGS 0
#endif

#define KEC_NET_HOSTMAX 256           /* DNS names cap at 253 bytes */
#define KEC_NET_RECVMAX (1 << 20)     /* per-call receive ceiling: 1 MiB */
#define KEC_NET_BACKLOG_DEFAULT 8

static const char g_net_tag;

/* The handle's backing. `fd` is -1 once closed, which is what makes tcp-close
** idempotent and keeps the finalizer from double-closing (or worse, closing a
** descriptor number the process has since reused).
**
** `ssl` is NULL on a plaintext socket and non-NULL once tls-connect has
** completed a handshake; every read and write below branches on it, which is
** what lets one set of send/recv/close primitives serve both. `ctx` is the
** SSL_CTX that produced `ssl`, kept here so the two are freed together.
**
** One SSL_CTX per connection is deliberate. A shared one would have to live
** somewhere with a lifetime tied to the interpreter, and the only correct
** places are a process global (which this tree avoids: independent contexts
** must not share mutable state) or new teardown plumbing through kec_close.
** The cost is re-reading the CA bundle per connect, a few milliseconds, which
** is invisible next to the handshake itself. */
typedef struct {
    int fd;
    SSL *ssl;
    SSL_CTX *ctx;
} NetSock;

/* ------------------------------------------------------------------ */
/* Typed FE_TPTR lifecycle.                                            */
/* ------------------------------------------------------------------ */

/* No nested Fe objects, so no mark handler is needed (NULL is accepted). */
static void net_gc(fe_Context *ctx, void *ptr) {
    NetSock *s = ptr;
    (void)ctx;
    if (s) {
        if (s->ssl) { SSL_free(s->ssl); }        /* dropped handle: no leak */
        if (s->ctx) { SSL_CTX_free(s->ctx); }
        if (s->fd >= 0) { close(s->fd); }
        free(s);
    }
}

static NetSock *as_sock(fe_Context *ctx, fe_Object *obj, const char *who) {
    char msg[64];
    NetSock *s;
    if (!fe_ptr_is_type(ctx, obj, &g_net_tag)) {
        snprintf(msg, sizeof msg, "%s: not a socket", who);
        fe_error(ctx, msg);
    }
    s = fe_toptr(ctx, obj);
    if (!s) { /* two-phase construction was interrupted; inert, never live */
        snprintf(msg, sizeof msg, "%s: not a socket", who);
        fe_error(ctx, msg);
    }
    return s;
}

/* As as_sock, but also rejects an already-closed handle. Every primitive that
** touches the descriptor goes through this. */
static NetSock *as_open_sock(fe_Context *ctx, fe_Object *obj, const char *who) {
    NetSock *s = as_sock(ctx, obj, who);
    char msg[64];
    if (s->fd < 0) {
        snprintf(msg, sizeof msg, "%s: socket is closed", who);
        fe_error(ctx, msg);
    }
    return s;
}

/* Handle creation is two-phase (docs/ffi-bridge.md §3), and the ORDER is the
** whole point: every primitive below calls net_handle BEFORE it opens a
** descriptor, then net_attach after.
**
** net_handle allocates the FE_TPTR with a NULL backing. That is the step that
** can raise out-of-memory and longjmp, and at that moment no descriptor exists
** to strand. fe_ptr_typed roots the object itself, so a later collection cannot
** take it. A NULL backing is inert everywhere (as_sock and net_gc both tolerate
** it), so a primitive that raises between the two phases leaves nothing behind.
**
** net_attach allocates the backing and hands it over with fe_set_ptr. No
** raising call sits between the malloc and the attach, and the malloc closes
** the descriptor itself if it fails. From fe_set_ptr onward net_gc owns it. */
static fe_Object *net_handle(fe_Context *ctx) {
    return fe_ptr_typed(ctx, NULL, &g_net_tag);
}

static void net_attach(fe_Context *ctx, fe_Object *obj, int fd, const char *who) {
    NetSock *s = malloc(sizeof *s);
    char msg[64];
    if (!s) {
        close(fd);
        snprintf(msg, sizeof msg, "%s: out of memory", who);
        fe_error(ctx, msg);
    }
    s->fd = fd;
    s->ssl = NULL;
    s->ctx = NULL;
    fe_set_ptr(ctx, obj, s);
}

/* ------------------------------------------------------------------ */
/* Argument helpers.                                                   */
/* ------------------------------------------------------------------ */

/* Pull the next argument as a bounded C string, raising rather than truncating
** (a clipped host name would connect somewhere else entirely). */
static void net_arg_str(fe_Context *ctx, fe_Object **args, char *buf, size_t size,
                        const char *who, const char *what) {
    fe_Object *v = fe_nextarg(ctx, args);
    char msg[96];
    if (kec_strlen_obj(ctx, v, 0) >= size) {
        snprintf(msg, sizeof msg, "%s: %s too long", who, what);
        fe_error(ctx, msg);
    }
    fe_tostring(ctx, v, buf, (int)size);
}

static int net_arg_port(fe_Context *ctx, fe_Object **args, const char *who, int allow_zero) {
    int32_t port = kec_checked_int(ctx, args, who);
    char msg[96];
    if (port < (allow_zero ? 0 : 1) || port > 65535) {
        snprintf(msg, sizeof msg, "%s: port must be %d..65535", who, allow_zero ? 0 : 1);
        fe_error(ctx, msg);
    }
    return (int)port;
}

/* Optional trailing timeout-ms argument. Returns -1 for "absent" (block
** indefinitely), which is also what poll() reads as "no timeout". */
static int net_arg_timeout(fe_Context *ctx, fe_Object **args, const char *who) {
    int32_t ms;
    char msg[96];
    if (fe_isnil(ctx, *args)) { return -1; }
    ms = kec_checked_int(ctx, args, who);
    if (ms < 0) {
        snprintf(msg, sizeof msg, "%s: timeout-ms must not be negative", who);
        fe_error(ctx, msg);
    }
    return (int)ms;
}

/* ------------------------------------------------------------------ */
/* Socket setup.                                                       */
/* ------------------------------------------------------------------ */

static void net_no_sigpipe(int fd) {
#ifdef SO_NOSIGPIPE
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#else
    (void)fd; /* Linux: MSG_NOSIGNAL on each send instead (KEC_SEND_FLAGS) */
#endif
}

/* Apply a read/write deadline so a peer that accepts the connection and then
** goes silent cannot wedge a script forever. Best-effort: a platform that
** rejects the option just keeps blocking semantics. */
static void net_set_timeouts(int fd, int timeout_ms) {
    struct timeval tv;
    if (timeout_ms < 0) { return; }
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

/* connect() with a deadline. SO_SNDTIMEO does not bound connect(), so a
** timeout means: flip to non-blocking, start the handshake, poll for
** writability, then read the real result out of SO_ERROR. Returns 0 on
** success; otherwise returns the errno-style code (ETIMEDOUT on expiry). */
static int net_connect(int fd, const struct sockaddr *sa, socklen_t len, int timeout_ms) {
    int flags, err = 0, rc;
    socklen_t elen = sizeof err;
    struct pollfd pfd;

    if (timeout_ms < 0) {
        return connect(fd, sa, len) == 0 ? 0 : errno;
    }

    flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { return errno; }
    if (connect(fd, sa, len) == 0) {
        err = 0;
    } else if (errno != EINPROGRESS) {
        err = errno;
    } else {
        pfd.fd = fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        do { rc = poll(&pfd, 1, timeout_ms); } while (rc < 0 && errno == EINTR);
        if (rc == 0) {
            err = ETIMEDOUT;
        } else if (rc < 0) {
            err = errno;
        } else if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) < 0) {
            err = errno;
        }
    }
    /* Restore blocking mode either way: the caller's read/write contract is
    ** blocking-with-SO_RCVTIMEO, not non-blocking. */
    fcntl(fd, F_SETFL, flags);
    return err;
}

/* ------------------------------------------------------------------ */
/* TLS.                                                                */
/* ------------------------------------------------------------------ */

/* Most recent OpenSSL error as a human string, for an fe_error message.
** Falls back to the SSL_get_error code when the error queue is empty (a
** syscall-level failure leaves nothing queued). */
static void net_ssl_reason(SSL *ssl, int rc, char *out, size_t outlen) {
    unsigned long e = ERR_get_error();
    if (e) {
        ERR_error_string_n(e, out, outlen);
        return;
    }
    switch (ssl ? SSL_get_error(ssl, rc) : SSL_ERROR_SYSCALL) {
        case SSL_ERROR_ZERO_RETURN:
            snprintf(out, outlen, "connection closed by peer");
            break;
        case SSL_ERROR_WANT_READ:
        case SSL_ERROR_WANT_WRITE:
            snprintf(out, outlen, "timed out");
            break;
        default:
            snprintf(out, outlen, "%s", errno ? strerror(errno) : "protocol error");
            break;
    }
}

/* True when `host` is a numeric address rather than a name. A certificate is
** matched against an IP SAN in that case, and SNI is omitted: RFC 6066 forbids
** a literal address in server_name, and a server may reject the handshake for
** it. */
static int net_is_ip_literal(const char *host) {
    unsigned char buf[16];
    return inet_pton(AF_INET, host, buf) == 1 || inet_pton(AF_INET6, host, buf) == 1;
}

/* Run the TLS handshake on an already-connected descriptor and attach the
** session to `s`. Verification is mandatory and configured BEFORE the
** handshake, so a failure aborts SSL_connect rather than being something the
** caller could forget to check afterwards:
**
**   SSL_CTX_set_verify(SSL_VERIFY_PEER)  chain must reach a trusted root
**   SSL_set1_host / SSL_set1_ip_asc      the name on the certificate must match
**
** Trust roots come from OpenSSL's compiled-in default paths, which the
** SSL_CERT_FILE and SSL_CERT_DIR environment variables override.
**
** On any failure this closes nothing: the caller owns the descriptor until
** net_attach runs, and s->ssl / s->ctx are freed here before raising. */
static void net_tls_start(fe_Context *ctx, NetSock *s, const char *host, int port) {
    char reason[192];
    char msg[KEC_NET_HOSTMAX + 320];
    SSL_CTX *sc;
    SSL *ssl;
    int rc;

    sc = SSL_CTX_new(TLS_client_method());
    if (!sc) { fe_error(ctx, "tls-connect: cannot create a TLS context"); }
    /* TLS 1.0/1.1 are withdrawn; refusing them here means a downgrade cannot
    ** be negotiated by the peer. */
    SSL_CTX_set_min_proto_version(sc, TLS1_2_VERSION);
    SSL_CTX_set_verify(sc, SSL_VERIFY_PEER, NULL);
    if (!SSL_CTX_set_default_verify_paths(sc)) {
        SSL_CTX_free(sc);
        fe_error(ctx, "tls-connect: no trusted CA store (set SSL_CERT_FILE)");
    }

    ssl = SSL_new(sc);
    if (!ssl) {
        SSL_CTX_free(sc);
        fe_error(ctx, "tls-connect: cannot create a TLS session");
    }
    SSL_set_fd(ssl, s->fd);

    {
        /* Name checking goes through the verification parameters, so a
        ** mismatch fails the handshake itself. Partial wildcards ("w*.a.com")
        ** are refused; a leading "*." label is still accepted, as everyone
        ** issues those. */
        X509_VERIFY_PARAM *vp = SSL_get0_param(ssl);
        int ok;
        /* NEVER_CHECK_SUBJECT is the important one. Without it OpenSSL falls
        ** back to matching the certificate's CN whenever the certificate has
        ** no dNSName SAN, which is the pre-RFC-6125 behavior browsers dropped:
        ** a CN is free-form text, so the fallback lets a certificate issued
        ** for one purpose satisfy a name it was never meant to cover. Every
        ** publicly-issued certificate has carried DNS SANs for years, so this
        ** costs nothing in practice; a hand-rolled internal certificate with
        ** only a CN will be refused, and should be reissued with a SAN.
        ** NO_PARTIAL_WILDCARDS refuses "w*.example.com" while still accepting
        ** an ordinary leading "*." label. */
        X509_VERIFY_PARAM_set_hostflags(vp, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS
                                            | X509_CHECK_FLAG_NEVER_CHECK_SUBJECT);
        if (net_is_ip_literal(host)) {
            ok = X509_VERIFY_PARAM_set1_ip_asc(vp, host);
        } else {
            SSL_set_tlsext_host_name(ssl, host); /* SNI, names only */
            ok = X509_VERIFY_PARAM_set1_host(vp, host, 0);
        }
        if (!ok) {
            SSL_free(ssl);
            SSL_CTX_free(sc);
            fe_error(ctx, "tls-connect: cannot pin the peer identity");
        }
    }

    ERR_clear_error();
    rc = SSL_connect(ssl);
    if (rc != 1) {
        long v = SSL_get_verify_result(ssl);
        if (v != X509_V_OK) {
            /* A rejected certificate is the interesting failure, so name it
            ** instead of the generic handshake error it also produces. */
            snprintf(msg, sizeof msg, "tls-connect: %s:%d: certificate rejected: %s",
                     host, port, X509_verify_cert_error_string(v));
        } else {
            net_ssl_reason(ssl, rc, reason, sizeof reason);
            snprintf(msg, sizeof msg, "tls-connect: %s:%d: %s", host, port, reason);
        }
        SSL_free(ssl);
        SSL_CTX_free(sc);
        fe_error(ctx, msg);
    }

    s->ssl = ssl;
    s->ctx = sc;
}

/* ------------------------------------------------------------------ */
/* Primitives.                                                         */
/* ------------------------------------------------------------------ */

/* Resolve `host` and connect, returning a connected descriptor or raising.
** Shared by tcp-connect and tls-connect so the two cannot drift on address
** family handling, timeouts, or error wording. */
static int net_dial(fe_Context *ctx, const char *host, int port, int timeout_ms,
                    const char *who) {
    char service[8];
    char msg[KEC_NET_HOSTMAX + 128];
    struct addrinfo hints, *res = NULL, *ai;
    int rc, fd = -1, last = 0;

    snprintf(service, sizeof service, "%d", port);
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    rc = getaddrinfo(host, service, &hints, &res);
    if (rc != 0) {
        snprintf(msg, sizeof msg, "%s: %s:%d: %s", who, host, port, gai_strerror(rc));
        fe_error(ctx, msg);
    }

    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) { last = errno; continue; }
        net_no_sigpipe(fd);
        last = net_connect(fd, ai->ai_addr, ai->ai_addrlen, timeout_ms);
        if (last == 0) { break; }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);

    if (fd < 0) {
        snprintf(msg, sizeof msg, "%s: %s:%d: %s", who, host, port,
                 strerror(last ? last : ECONNREFUSED));
        fe_error(ctx, msg);
    }
    net_set_timeouts(fd, timeout_ms);
    return fd;
}

/* (tcp-connect host port [timeout-ms]) -> socket handle.
** Resolves host (IPv4 or IPv6) and connects to the first address that answers.
** With timeout-ms the handshake is bounded AND the handle carries the same
** value as its read/write deadline. Failure raises a catchable error naming the
** host, the port, and strerror of the last attempt. Cleartext: for an HTTPS
** endpoint use tls-connect. */
static fe_Object *h_tcp_connect(fe_Context *ctx, fe_Object *args) {
    char host[KEC_NET_HOSTMAX];
    int port, timeout_ms, fd;
    fe_Object *handle;

    net_arg_str(ctx, &args, host, sizeof host, "tcp-connect", "host");
    port = net_arg_port(ctx, &args, "tcp-connect", 0);
    timeout_ms = net_arg_timeout(ctx, &args, "tcp-connect");

    handle = net_handle(ctx); /* phase 1, before a descriptor exists */
    fd = net_dial(ctx, host, port, timeout_ms, "tcp-connect");
    net_attach(ctx, handle, fd, "tcp-connect");
    return handle;
}

/* (tls-connect host port [timeout-ms]) -> socket handle.
** As tcp-connect, then a TLS handshake. The result is an ordinary socket
** handle: tcp-send, tcp-recv, and tcp-close all work on it unchanged, so
** protocol code written for cleartext runs over TLS with no edit.
**
** The peer certificate is ALWAYS verified, both chain and host name, and a
** failure raises with the reason (an expired certificate and a name mismatch
** report differently). There is no flag to skip it.
**
** The descriptor is attached to the handle BEFORE the handshake runs, so a
** handshake failure still leaves the fd owned by the handle's finalizer rather
** than stranded. */
static fe_Object *h_tls_connect(fe_Context *ctx, fe_Object *args) {
    char host[KEC_NET_HOSTMAX];
    int port, timeout_ms, fd;
    fe_Object *handle;

    net_arg_str(ctx, &args, host, sizeof host, "tls-connect", "host");
    port = net_arg_port(ctx, &args, "tls-connect", 0);
    timeout_ms = net_arg_timeout(ctx, &args, "tls-connect");

    handle = net_handle(ctx);
    fd = net_dial(ctx, host, port, timeout_ms, "tls-connect");
    net_attach(ctx, handle, fd, "tls-connect");
    net_tls_start(ctx, fe_toptr(ctx, handle), host, port);
    return handle;
}

/* (tcp-send handle value) -> bytes written.
** A blob is sent verbatim (binary-safe, matching write-file); any other value
** is stringified the way princ/str render it. Loops until the whole payload is
** written, so a short write is invisible to callers. */
static fe_Object *h_tcp_send(fe_Context *ctx, fe_Object *args) {
    NetSock *s = as_open_sock(ctx, fe_nextarg(ctx, &args), "tcp-send");
    fe_Object *val = fe_nextarg(ctx, &args);
    const unsigned char *blob;
    const char *p;
    char *body = NULL;
    size_t len, sent = 0;
    char msg[96];

    if (kec_blob_bytes(ctx, val, &blob, &len)) {
        p = (const char *)blob; /* borrowed from the blob's backing; no free */
    } else {
        body = kec_strdup_obj(ctx, val, 0, &len);
        if (!body) { fe_error(ctx, "tcp-send: out of memory"); }
        /* Registered for the whole loop: every fe_error below unwinds by
        ** longjmp, and the runtime's handler frees what is still registered. */
        kec_pending_push(ctx, body);
        p = body;
    }

    while (sent < len) {
        ssize_t w;
        if (s->ssl) {
            int n;
            ERR_clear_error();
            n = SSL_write(s->ssl, p + sent, (int)(len - sent));
            if (n <= 0) {
                char reason[192];
                if (SSL_get_error(s->ssl, n) == SSL_ERROR_SYSCALL && errno == EINTR) {
                    continue;
                }
                net_ssl_reason(s->ssl, n, reason, sizeof reason);
                snprintf(msg, sizeof msg, "tcp-send: %s", reason);
                fe_error(ctx, msg); /* body (if any) is freed by the handler */
            }
            w = (ssize_t)n;
        } else {
            w = send(s->fd, p + sent, len - sent, KEC_SEND_FLAGS);
            if (w < 0) {
                if (errno == EINTR) { continue; }
                snprintf(msg, sizeof msg, "tcp-send: %s", strerror(errno));
                fe_error(ctx, msg); /* body (if any) is freed by the handler */
            }
        }
        sent += (size_t)w;
    }

    if (body) {
        kec_pending_pop(ctx, body);
        free(body);
    }
    return fe_number(ctx, (fe_Number)sent);
}

/* (tcp-recv handle max-bytes) -> string, or nil at clean EOF.
** Returns whatever one read yields, up to max-bytes, which may be less than the
** full amount, so callers loop. High bytes survive; an embedded NUL does not (the
** string type is NUL-terminated), which caps the contract at text. Use the peer
** protocol's own framing (Content-Length / chunked) rather than EOF when the
** payload may be binary. A configured timeout expiring raises rather than
** returning nil, so a stall is never mistaken for end-of-stream. */
static fe_Object *h_tcp_recv(fe_Context *ctx, fe_Object *args) {
    NetSock *s = as_open_sock(ctx, fe_nextarg(ctx, &args), "tcp-recv");
    int32_t max = kec_checked_int(ctx, &args, "tcp-recv");
    char *buf;
    ssize_t n;
    fe_Object *res;
    char msg[96];

    if (max < 1 || max > KEC_NET_RECVMAX) {
        snprintf(msg, sizeof msg, "tcp-recv: max-bytes must be 1..%d", KEC_NET_RECVMAX);
        fe_error(ctx, msg);
    }
    buf = malloc((size_t)max + 1);
    if (!buf) { fe_error(ctx, "tcp-recv: out of memory"); }
    kec_pending_push(ctx, buf); /* fe_string below may raise out-of-memory */

    if (s->ssl) {
        int r;
        do {
            ERR_clear_error();
            r = SSL_read(s->ssl, buf, max);
        } while (r <= 0 && SSL_get_error(s->ssl, r) == SSL_ERROR_SYSCALL
                 && errno == EINTR);
        if (r <= 0) {
            int e = SSL_get_error(s->ssl, r);
            /* A close_notify is the TLS spelling of a clean EOF. So is a
            ** connection the peer dropped after shutting down the session. */
            if (e == SSL_ERROR_ZERO_RETURN
                || (e == SSL_ERROR_SYSCALL && ERR_peek_error() == 0 && errno == 0)) {
                n = 0;
            } else {
                char reason[192];
                net_ssl_reason(s->ssl, r, reason, sizeof reason);
                kec_pending_pop(ctx, buf);
                free(buf);
                snprintf(msg, sizeof msg, "tcp-recv: %s", reason);
                fe_error(ctx, msg);
                n = 0; /* unreachable */
            }
        } else {
            n = (ssize_t)r;
        }
    } else {
        do { n = recv(s->fd, buf, (size_t)max, 0); } while (n < 0 && errno == EINTR);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                fe_error(ctx, "tcp-recv: timed out");
            }
            snprintf(msg, sizeof msg, "tcp-recv: %s", strerror(errno));
            fe_error(ctx, msg);
        }
    }
    if (n == 0) { /* orderly shutdown by the peer */
        kec_pending_pop(ctx, buf);
        free(buf);
        return fe_bool(ctx, 0);
    }
    buf[n] = '\0';
    res = fe_string(ctx, buf);
    kec_pending_pop(ctx, buf);
    free(buf);
    return res;
}

/* (tcp-close handle) -> nil. Idempotent: closing an already-closed handle is
** not an error, and the finalizer skips a descriptor closed here. */
static fe_Object *h_tcp_close(fe_Context *ctx, fe_Object *args) {
    NetSock *s = as_sock(ctx, fe_nextarg(ctx, &args), "tcp-close");
    if (s->ssl) {
        /* Send close_notify so the peer sees an orderly shutdown rather than a
        ** truncation. One try only: a peer that has already gone does not get
        ** to block a close. */
        SSL_shutdown(s->ssl);
        SSL_free(s->ssl);
        s->ssl = NULL;
    }
    if (s->ctx) {
        SSL_CTX_free(s->ctx);
        s->ctx = NULL;
    }
    if (s->fd >= 0) {
        close(s->fd);
        s->fd = -1;
    }
    return fe_bool(ctx, 0);
}

/* (tcp-listen port [backlog]) -> listener handle.
** Binds 127.0.0.1 only. Its purpose is to let the conformance suite exercise
** the primitives without touching the outside world. Port 0 takes an ephemeral
** port; read it back with tcp-port rather than guessing at a free one.
** SO_REUSEADDR is set so a listener in TIME_WAIT from a previous run does not
** block a rebind. */
static fe_Object *h_tcp_listen(fe_Context *ctx, fe_Object *args) {
    int port = net_arg_port(ctx, &args, "tcp-listen", 1);
    int backlog = KEC_NET_BACKLOG_DEFAULT;
    struct sockaddr_in addr;
    int fd, on = 1;
    char msg[96];
    fe_Object *handle;

    if (!fe_isnil(ctx, args)) {
        backlog = (int)kec_checked_int(ctx, &args, "tcp-listen");
        if (backlog < 1) { fe_error(ctx, "tcp-listen: backlog must be positive"); }
    }

    handle = net_handle(ctx); /* phase 1, before a descriptor exists */
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        snprintf(msg, sizeof msg, "tcp-listen: %s", strerror(errno));
        fe_error(ctx, msg);
    }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    net_no_sigpipe(fd);

    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, backlog) != 0) {
        int err = errno;
        close(fd);
        snprintf(msg, sizeof msg, "tcp-listen: 127.0.0.1:%d: %s", port, strerror(err));
        fe_error(ctx, msg);
    }
    net_attach(ctx, handle, fd, "tcp-listen");
    return handle;
}

/* (tcp-port handle) -> the local port this socket is bound to.
** The reason it exists: (tcp-listen 0) takes an ephemeral port, which is the
** only way to bind without guessing, and without a readback a caller would have
** to scan a fixed range and hope. Works on a listener or a connected socket. */
static fe_Object *h_tcp_port(fe_Context *ctx, fe_Object *args) {
    NetSock *s = as_open_sock(ctx, fe_nextarg(ctx, &args), "tcp-port");
    struct sockaddr_storage ss;
    socklen_t len = sizeof ss;
    char msg[96];
    int port;

    memset(&ss, 0, sizeof ss);
    if (getsockname(s->fd, (struct sockaddr *)&ss, &len) != 0) {
        snprintf(msg, sizeof msg, "tcp-port: %s", strerror(errno));
        fe_error(ctx, msg);
    }
    if (ss.ss_family == AF_INET) {
        port = ntohs(((struct sockaddr_in *)(void *)&ss)->sin_port);
    } else if (ss.ss_family == AF_INET6) {
        port = ntohs(((struct sockaddr_in6 *)(void *)&ss)->sin6_port);
    } else {
        fe_error(ctx, "tcp-port: socket is not IPv4 or IPv6");
        port = 0; /* unreachable: fe_error longjmps */
    }
    return fe_number(ctx, (fe_Number)port);
}

/* (tcp-accept handle [timeout-ms]) -> socket handle, or nil on timeout.
** With no timeout it blocks. The accepted socket inherits timeout-ms as its
** read/write deadline, so a test peer can never hang the suite. */
static fe_Object *h_tcp_accept(fe_Context *ctx, fe_Object *args) {
    NetSock *s = as_open_sock(ctx, fe_nextarg(ctx, &args), "tcp-accept");
    int timeout_ms = net_arg_timeout(ctx, &args, "tcp-accept");
    struct pollfd pfd;
    int rc, fd;
    char msg[96];
    fe_Object *handle;

    pfd.fd = s->fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    do { rc = poll(&pfd, 1, timeout_ms); } while (rc < 0 && errno == EINTR);
    if (rc < 0) {
        snprintf(msg, sizeof msg, "tcp-accept: %s", strerror(errno));
        fe_error(ctx, msg);
    }
    if (rc == 0) { return fe_bool(ctx, 0); } /* timed out, which is not an error */

    handle = net_handle(ctx); /* phase 1, before a descriptor exists */
    do { fd = accept(s->fd, NULL, NULL); } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        snprintf(msg, sizeof msg, "tcp-accept: %s", strerror(errno));
        fe_error(ctx, msg);
    }
    net_no_sigpipe(fd);
    net_set_timeouts(fd, timeout_ms);
    net_attach(ctx, handle, fd, "tcp-accept");
    return handle;
}

/* ------------------------------------------------------------------ */
/* Registration.                                                       */
/* ------------------------------------------------------------------ */

void kec_net_register(fe_Context *ctx, kec_Profile profile) {
    if (profile != KEC_PROFILE_FULL) { return; } /* sandbox gets no sockets */

    if (fe_register_ptr_type(ctx, &g_net_tag, NULL, net_gc) != 0) {
        fe_error(ctx, "socket foreign pointer type registration failed");
    }
    kec_bind_fe(ctx, "tcp-connect", h_tcp_connect);
    kec_bind_fe(ctx, "tls-connect", h_tls_connect);
    kec_bind_fe(ctx, "tcp-send", h_tcp_send);
    kec_bind_fe(ctx, "tcp-recv", h_tcp_recv);
    kec_bind_fe(ctx, "tcp-close", h_tcp_close);
    kec_bind_fe(ctx, "tcp-listen", h_tcp_listen);
    kec_bind_fe(ctx, "tcp-accept", h_tcp_accept);
    kec_bind_fe(ctx, "tcp-port", h_tcp_port);
}

#else /* !KEC_NET_POSIX */

/* No <sys/socket.h>: register nothing. (bound? 'tcp-connect) is the portable
** way for Lisp to discover that, exactly as with a profile gate. */
void kec_net_register(fe_Context *ctx, kec_Profile profile) {
    (void)ctx;
    (void)profile;
}

#endif /* KEC_NET_POSIX */
