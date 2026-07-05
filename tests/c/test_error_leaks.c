/*
** test_error_leaks.c — C-level regressions for the error-path resource-leak
** class (review sweep; third pass after GWP-235 and GWP-584): a resource held
** across a call that can raise via fe_error's longjmp must be released on the
** unwind, because a fixed-arena device that catches errors and keeps running
** accumulates every miss forever.
**
** Heap-buffer leaks are invisible to an assertion without allocator
** interposition, so the observable proxy here is the fd table: RLIMIT_NOFILE
** is lowered and a failing-(load)-inside-(try) loop must not exhaust it.
** The GC-stack growth companions live at the Lisp level
** (tests/core/applyread.lsp, tests/core/eval.lsp).
*/
#include "kec.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

static int g_failures;

#define CHECK(cond, msg)                                                        \
    do {                                                                        \
        if (!(cond)) {                                                          \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);   \
            g_failures++;                                                       \
        }                                                                       \
    } while (0)

static void write_text_file(const char *path, const char *text) {
    FILE *fp = fopen(path, "wb");
    CHECK(fp != NULL, "test fixture file did not open for writing");
    if (!fp) { return; }
    fputs(text, fp);
    fclose(fp);
}

/* Evaluate src and CHECK the result prints exactly as `expect`. */
static void check_prints(kec_State *S, const char *src, const char *expect,
                         const char *msg) {
    fe_Object *out = NULL;
    char buf[256];
    int rc = kec_eval_string(S, src, &out);
    CHECK(rc == 0 && out != NULL, "evaluation failed");
    if (rc != 0 || !out) { return; }
    fe_tostring(kec_fe(S), out, buf, sizeof buf);
    CHECK(strcmp(buf, expect) == 0, msg);
    if (strcmp(buf, expect) != 0) {
        fprintf(stderr, "  (got \"%s\", want \"%s\")\n", buf, expect);
    }
}

/* Every failing (load) — a raising form, a syntax error, or a nested load
** whose inner file raises — used to leak its FILE*: fe_read / fe_eval unwind
** with longjmp straight past the fclose. Repeated failing loads inside (try)
** then exhausted the fd table. With the fd ceiling lowered to 64, a 200-round
** loop trips the old leak long before it finishes. */
static void test_failing_load_does_not_leak_fds(void) {
    struct rlimit orig, lowered;
    int have_rlimit = (getrlimit(RLIMIT_NOFILE, &orig) == 0);
    kec_State *S;
    int i;

    if (have_rlimit) {
        lowered = orig;
        lowered.rlim_cur = 64;
        setrlimit(RLIMIT_NOFILE, &lowered);
    }

    write_text_file("kec-leak-raise.tmp", "(raise \"boom\")\n");
    write_text_file("kec-leak-syntax.tmp", "(1 2");
    write_text_file("kec-leak-nested.tmp", "(load \"kec-leak-raise.tmp\")\n");

    S = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    CHECK(S != NULL, "context did not open for fd-leak test");
    if (!S) { return; }

    for (i = 0; i < 200; i++) {
        if (kec_eval_string(S, "(try (fn () (load \"kec-leak-raise.tmp\")))", NULL) != 0 ||
            kec_eval_string(S, "(try (fn () (load \"kec-leak-syntax.tmp\")))", NULL) != 0 ||
            kec_eval_string(S, "(try (fn () (load \"kec-leak-nested.tmp\")))", NULL) != 0) {
            CHECK(0, "(try (fn () (load ...))) did not catch the load error");
            break;
        }
    }

    /* The fd table must still have room after 600 failing loads. */
    {
        FILE *probe = fopen("kec-leak-raise.tmp", "rb");
        CHECK(probe != NULL, "fd table exhausted: failing (load) leaked FILE*s");
        if (probe) { fclose(probe); }
    }

    /* The caught message must be the script's own error — proving the close-on
    ** -unwind guard re-raises faithfully, including through a nested load. */
    check_prints(S, "(cdr (try (fn () (load \"kec-leak-raise.tmp\"))))", "boom",
                 "load error message was not preserved through the unwind guard");
    check_prints(S, "(cdr (try (fn () (load \"kec-leak-nested.tmp\"))))", "boom",
                 "nested load error message was not preserved");

    kec_close(S);
    remove("kec-leak-raise.tmp");
    remove("kec-leak-syntax.tmp");
    remove("kec-leak-nested.tmp");
    if (have_rlimit) { setrlimit(RLIMIT_NOFILE, &orig); }
}

/* The reader primitives hold a heap materialization of their argument while
** fe_read parses it; a syntax error must unwind catchably (the buffer free is
** covered by the pending-buffer registry; observable only under LSan, but the
** catchability contract is checkable here). */
static void test_reader_syntax_errors_are_catchable(void) {
    kec_State *S = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    int i;
    CHECK(S != NULL, "context did not open for reader test");
    if (!S) { return; }
    for (i = 0; i < 100; i++) {
        if (kec_eval_string(S, "(try (fn () (read-string \"(1 2\")))", NULL) != 0 ||
            kec_eval_string(S, "(try (fn () (read-all \"(a (b)\")))", NULL) != 0) {
            CHECK(0, "reader syntax error escaped (try ...)");
            break;
        }
    }
    check_prints(S, "(if (error? (try (fn () (read-string \"(1 2\")))) 1 0)", "1",
                 "read-string syntax error was not a catchable :error");
    kec_close(S);
}

int main(void) {
    test_failing_load_does_not_leak_fds();
    test_reader_syntax_errors_are_catchable();
    if (g_failures == 0) { printf("test_error_leaks: all checks passed\n"); }
    return g_failures;
}
