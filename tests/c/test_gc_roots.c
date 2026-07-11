/*
** test_gc_roots.c — regression for the public-eval GC-root leak (GWP-700):
** every kec_eval_string / kec_eval_file / kec_check_string call left at least
** one object pinned on the Fe GC root stack (run_forms never restored its
** save point on the success path), so a long-lived embedder that evaluates
** per event or tick — the nOSh runtime — marched the root stack to its cap
** (GCSTACKSIZE, 256 on the device) and every later eval died with
** "gc stack overflow". The desktop build's 8192-slot stack only masked it.
**
** Contract under test: a public eval call may pin at most its own result
** (dropped again by the next public call), so after N calls the root-stack
** top sits at most a small constant above where it started — never O(N).
*/
#include "kec.h"

#include <stdio.h>
#include <string.h>

static int g_failures;

#define CHECK(cond, msg)                                                        \
    do {                                                                        \
        if (!(cond)) {                                                          \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);   \
            g_failures++;                                                       \
        }                                                                       \
    } while (0)

#define ROUNDS 500
#define ROOT_SLACK 2 /* the pinned last result, plus margin */

static void test_eval_string_roots_bounded(void) {
    kec_State *S = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    int before, after, i;
    CHECK(S != NULL, "context did not open for eval-string root test");
    if (!S) { return; }
    before = fe_savegc(kec_fe(S));
    for (i = 0; i < ROUNDS; i++) {
        char src[64];
        fe_Object *out = NULL;
        snprintf(src, sizeof src, "(+ %d 1)", i);
        if (kec_eval_string(S, src, &out) != 0) {
            CHECK(0, "eval-string failed mid-loop");
            break;
        }
        /* The result must be usable (still rooted) right after the call. */
        if (!(out && fe_type(kec_fe(S), out) == FE_TNUMBER &&
              (int)fe_tonumber(kec_fe(S), out) == i + 1)) {
            CHECK(0, "eval-string result was wrong or unrooted");
            break;
        }
    }
    after = fe_savegc(kec_fe(S));
    CHECK(after - before <= ROOT_SLACK,
          "kec_eval_string accumulated GC roots across repeated calls");
    kec_close(S);
}

/* Error-path calls must not accumulate roots either: the guard's recovery
** already restores to the entry save point, and the entry baseline reset must
** hold across a mix of failing and succeeding evals. */
static void test_eval_string_error_roots_bounded(void) {
    kec_State *S = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    int before, after, i;
    CHECK(S != NULL, "context did not open for error-path root test");
    if (!S) { return; }
    before = fe_savegc(kec_fe(S));
    for (i = 0; i < ROUNDS; i++) {
        fe_Object *out = NULL;
        if (kec_eval_string(S, "(car 1)", &out) == 0) {
            CHECK(0, "(car 1) unexpectedly succeeded");
            break;
        }
        if (kec_eval_string(S, "(list 1 2 3)", &out) != 0) {
            CHECK(0, "eval-string failed after a recovered error");
            break;
        }
    }
    after = fe_savegc(kec_fe(S));
    CHECK(after - before <= ROOT_SLACK,
          "error-path evals accumulated GC roots across repeated calls");
    kec_close(S);
}

static void test_check_string_roots_bounded(void) {
    kec_State *S = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    int before, after, i;
    CHECK(S != NULL, "context did not open for check-string root test");
    if (!S) { return; }
    before = fe_savegc(kec_fe(S));
    for (i = 0; i < ROUNDS; i++) {
        if (kec_check_string(S, "(fn (x) (+ x 1))") != 0) {
            CHECK(0, "check-string failed on valid source");
            break;
        }
    }
    after = fe_savegc(kec_fe(S));
    CHECK(after - before <= ROOT_SLACK,
          "kec_check_string accumulated GC roots across repeated calls");
    kec_close(S);
}

static void test_eval_file_roots_bounded(void) {
    kec_State *S = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    int before, after, i;
    FILE *fp;
    CHECK(S != NULL, "context did not open for eval-file root test");
    if (!S) { return; }
    fp = fopen("kec-gc-roots.tmp", "wb");
    CHECK(fp != NULL, "test fixture file did not open for writing");
    if (!fp) { kec_close(S); return; }
    fputs("(set gc-roots-probe (+ 40 2))\ngc-roots-probe\n", fp);
    fclose(fp);
    before = fe_savegc(kec_fe(S));
    for (i = 0; i < ROUNDS; i++) {
        fe_Object *out = NULL;
        if (kec_eval_file(S, "kec-gc-roots.tmp", &out) != 0) {
            CHECK(0, "eval-file failed mid-loop");
            break;
        }
        if (!(out && fe_type(kec_fe(S), out) == FE_TNUMBER &&
              (int)fe_tonumber(kec_fe(S), out) == 42)) {
            CHECK(0, "eval-file result was wrong or unrooted");
            break;
        }
    }
    after = fe_savegc(kec_fe(S));
    CHECK(after - before <= ROOT_SLACK,
          "kec_eval_file accumulated GC roots across repeated calls");
    kec_close(S);
    remove("kec-gc-roots.tmp");
}

int main(void) {
    test_eval_string_roots_bounded();
    test_eval_string_error_roots_bounded();
    test_check_string_roots_bounded();
    test_eval_file_roots_bounded();
    if (g_failures == 0) { printf("test_gc_roots: all checks passed\n"); }
    return g_failures;
}
