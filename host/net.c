/*
** net.c — KEC Lisp's TCP socket primitives.
**
** Seven primitives (tcp-connect / tcp-send / tcp-recv / tcp-close / tcp-listen /
** tcp-accept / tcp-port), FULL profile only, POSIX sockets only, no link
** dependency beyond libc. Everything above the byte stream (HTTP framing,
** JSON, URL encoding) is written in KEC Lisp (core/68-json.lsp,
** examples/http/http.lsp). TLS is NOT
** here and is not planned: terminate it out of process with stunnel or socat
** and speak cleartext to the local listener (see docs/networking.md, ADR-0007).
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
** descriptor number the process has since reused). */
typedef struct {
    int fd;
} NetSock;

/* ------------------------------------------------------------------ */
/* Typed FE_TPTR lifecycle.                                            */
/* ------------------------------------------------------------------ */

/* No nested Fe objects, so no mark handler is needed (NULL is accepted). */
static void net_gc(fe_Context *ctx, void *ptr) {
    NetSock *s = ptr;
    (void)ctx;
    if (s) {
        if (s->fd >= 0) { close(s->fd); } /* dropped handle: no fd leak */
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
/* Primitives.                                                         */
/* ------------------------------------------------------------------ */

/* (tcp-connect host port [timeout-ms]) -> socket handle.
** Resolves host (IPv4 or IPv6) and connects to the first address that answers.
** With timeout-ms the handshake is bounded AND the handle carries the same
** value as its read/write deadline. Failure raises a catchable error naming the
** host, the port, and strerror of the last attempt. */
static fe_Object *h_tcp_connect(fe_Context *ctx, fe_Object *args) {
    char host[KEC_NET_HOSTMAX];
    char service[8];
    char msg[KEC_NET_HOSTMAX + 128];
    struct addrinfo hints, *res = NULL, *ai;
    int port, timeout_ms, rc, fd = -1, last = 0;
    fe_Object *handle;

    net_arg_str(ctx, &args, host, sizeof host, "tcp-connect", "host");
    port = net_arg_port(ctx, &args, "tcp-connect", 0);
    timeout_ms = net_arg_timeout(ctx, &args, "tcp-connect");
    snprintf(service, sizeof service, "%d", port);
    handle = net_handle(ctx); /* phase 1, before a descriptor exists */

    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    rc = getaddrinfo(host, service, &hints, &res);
    if (rc != 0) {
        snprintf(msg, sizeof msg, "tcp-connect: %s:%d: %s", host, port, gai_strerror(rc));
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
        snprintf(msg, sizeof msg, "tcp-connect: %s:%d: %s", host, port,
                 strerror(last ? last : ECONNREFUSED));
        fe_error(ctx, msg);
    }
    net_set_timeouts(fd, timeout_ms);
    net_attach(ctx, handle, fd, "tcp-connect");
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
        ssize_t w = send(s->fd, p + sent, len - sent, KEC_SEND_FLAGS);
        if (w < 0) {
            if (errno == EINTR) { continue; }
            snprintf(msg, sizeof msg, "tcp-send: %s", strerror(errno));
            fe_error(ctx, msg); /* body (if any) is freed by the error handler */
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

    do { n = recv(s->fd, buf, (size_t)max, 0); } while (n < 0 && errno == EINTR);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            fe_error(ctx, "tcp-recv: timed out");
        }
        snprintf(msg, sizeof msg, "tcp-recv: %s", strerror(errno));
        fe_error(ctx, msg);
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
