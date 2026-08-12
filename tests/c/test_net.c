/*
** test_net.c — C-level conformance for the socket seam (host/net.c).
**
** Two things the .lsp suite cannot reach from inside a single FULL context:
**
**   1. PROFILE GATING. `kec test` runs in one FULL context, so it can assert
**      the primitives are present but never that a SANDBOX context lacks them.
**      That needs a second interpreter, which only C can open.
**   2. THE FINALIZER. A socket handle dropped without tcp-close must have its
**      descriptor closed by the typed-FE_TPTR gc handler. Lisp cannot observe a
**      file descriptor; C can, because POSIX guarantees socket() returns the
**      LOWEST free descriptor, so a probe taken and released just beforehand
**      names exactly the descriptor the next socket will take.
**
** Exit code 0 = all assertions held.
*/
#include "kec.h"

#include <stdio.h>
#include <string.h>

#if defined(__has_include)
#if __has_include(<sys/socket.h>)
#define KEC_NET_POSIX 1
#endif
#elif defined(__unix__) || defined(__unix) || (defined(__APPLE__) && defined(__MACH__))
#define KEC_NET_POSIX 1
#endif

#ifdef KEC_NET_POSIX
#include <fcntl.h>
#include <unistd.h>
#endif

#define ARENA_BYTES (4u * 1024u * 1024u)

static int g_failures = 0;

#define CHECK(cond, msg)                                                        \
    do {                                                                        \
        if (!(cond)) {                                                          \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);   \
            g_failures++;                                                       \
        }                                                                       \
    } while (0)

/* Evaluate `src` and report whether the result was truthy. An eval error
** counts as nil, which is what a missing binding would produce anyway. */
static int truthy(kec_State *S, const char *src) {
    fe_Object *out = NULL;
    if (kec_eval_string(S, src, &out) != 0 || !out) { return 0; }
    return !fe_isnil(kec_fe(S), out);
}

/* Every socket primitive, plus sleep, is absent from a SANDBOX context, the
** same way the file and system primitives are. A context can only call what
** was bound into it; that IS the sandbox. */
static void test_sandbox_has_no_network(void) {
    kec_State *S = kec_open(ARENA_BYTES, KEC_PROFILE_SANDBOX);
    CHECK(S != NULL, "kec_open(SANDBOX) returned NULL");
    if (!S) { return; }

    CHECK(!truthy(S, "(bound? 'tcp-connect)"), "SANDBOX exposes tcp-connect");
    CHECK(!truthy(S, "(bound? 'tcp-send)"), "SANDBOX exposes tcp-send");
    CHECK(!truthy(S, "(bound? 'tcp-recv)"), "SANDBOX exposes tcp-recv");
    CHECK(!truthy(S, "(bound? 'tcp-close)"), "SANDBOX exposes tcp-close");
    CHECK(!truthy(S, "(bound? 'tcp-listen)"), "SANDBOX exposes tcp-listen");
    CHECK(!truthy(S, "(bound? 'tcp-accept)"), "SANDBOX exposes tcp-accept");
    CHECK(!truthy(S, "(bound? 'sleep)"), "SANDBOX exposes sleep");

    /* Control: the portable primitives a sandbox DOES get are still there, so
    ** the assertions above are testing the gate and not a broken context. */
    CHECK(truthy(S, "(bound? 'string-length)"), "SANDBOX lost string-length");
    CHECK(truthy(S, "(bound? 'make-hash-table)"), "SANDBOX lost make-hash-table");
    CHECK(truthy(S, "(bound? 'json-parse)"), "SANDBOX lost json-parse");
    /* ... and the file/system gate this one mirrors */
    CHECK(!truthy(S, "(bound? 'read-file)"), "SANDBOX exposes read-file");

    kec_close(S);
}

static void test_full_has_network(void) {
    kec_State *S = kec_open(ARENA_BYTES, KEC_PROFILE_FULL);
    CHECK(S != NULL, "kec_open(FULL) returned NULL");
    if (!S) { return; }

#ifdef KEC_NET_POSIX
    CHECK(truthy(S, "(bound? 'tcp-connect)"), "FULL is missing tcp-connect");
    CHECK(truthy(S, "(bound? 'tcp-listen)"), "FULL is missing tcp-listen");
    CHECK(truthy(S, "(bound? 'tcp-accept)"), "FULL is missing tcp-accept");
    CHECK(truthy(S, "(bound? 'tcp-send)"), "FULL is missing tcp-send");
    CHECK(truthy(S, "(bound? 'tcp-recv)"), "FULL is missing tcp-recv");
    CHECK(truthy(S, "(bound? 'tcp-close)"), "FULL is missing tcp-close");
#endif
    CHECK(truthy(S, "(bound? 'sleep)"), "FULL is missing sleep");

    kec_close(S);
}

#ifdef KEC_NET_POSIX

/* The lowest free descriptor: POSIX assigns it to the next socket()/dup(). */
static int probe_next_fd(void) {
    int fd = dup(0);
    if (fd >= 0) { close(fd); }
    return fd;
}

static int fd_is_open(int fd) {
    return fcntl(fd, F_GETFD) != -1;
}

/* A handle dropped without tcp-close still releases its descriptor: the typed
** pointer's gc handler closes it. fe_close sweeps every live object, so the
** guarantee is observable at kec_close even if the collector never ran. */
static void test_dropped_handle_closes_its_fd(void) {
    kec_State *S = kec_open(ARENA_BYTES, KEC_PROFILE_FULL);
    int fd;
    CHECK(S != NULL, "kec_open(FULL) returned NULL");
    if (!S) { return; }

    fd = probe_next_fd();
    CHECK(fd >= 0, "could not probe the next free descriptor");
    /* The handle is never stored anywhere: nothing but the finalizer can
    ** close it. */
    CHECK(kec_eval_string(S, "(do (tcp-listen 0) nil)", NULL) == 0,
          "(tcp-listen 0) errored");
    CHECK(fd_is_open(fd), "the listener did not take the probed descriptor");

    kec_close(S);
    CHECK(!fd_is_open(fd), "descriptor still open after kec_close: the "
                           "finalizer leaked it");
}

/* An explicit tcp-close releases the descriptor immediately, and marks the
** handle so the finalizer does not close that number a second time (by then it
** could belong to something else entirely). */
static void test_explicit_close_releases_then_finalizer_is_a_no_op(void) {
    kec_State *S = kec_open(ARENA_BYTES, KEC_PROFILE_FULL);
    int fd;
    CHECK(S != NULL, "kec_open(FULL) returned NULL");
    if (!S) { return; }

    fd = probe_next_fd();
    CHECK(fd >= 0, "could not probe the next free descriptor");
    CHECK(kec_eval_string(S, "(let %sock (tcp-listen 0))", NULL) == 0,
          "(tcp-listen 0) errored");
    CHECK(fd_is_open(fd), "the listener did not take the probed descriptor");

    CHECK(kec_eval_string(S, "(do (tcp-close %sock) (tcp-close %sock) nil)", NULL) == 0,
          "tcp-close raised (it must be idempotent)");
    CHECK(!fd_is_open(fd), "descriptor still open after tcp-close");

    /* Re-take the descriptor number from C. If the finalizer closed it again
    ** at kec_close, THIS is what it would destroy. */
    {
        int taken = dup(0);
        CHECK(taken == fd, "expected to reclaim the released descriptor number");
        kec_close(S);
        CHECK(fd_is_open(taken), "the finalizer closed a descriptor it no longer owned");
        close(taken);
    }
}

#endif /* KEC_NET_POSIX */

int main(void) {
    test_sandbox_has_no_network();
    test_full_has_network();
#ifdef KEC_NET_POSIX
    test_dropped_handle_closes_its_fd();
    test_explicit_close_releases_then_finalizer_is_a_no_op();
#endif
    if (g_failures) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("net: all C-level assertions held\n");
    return 0;
}
