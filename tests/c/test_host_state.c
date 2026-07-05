/*
** C-level regressions for context-owned host state and composable FE_TPTR
** lifecycle handling (GWP-235).
*/
#include "kec.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures;

#define CHECK(cond, msg)                                                        \
    do {                                                                        \
        if (!(cond)) {                                                          \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);   \
            g_failures++;                                                       \
        }                                                                       \
    } while (0)

static int eval_int(kec_State *S, const char *src) {
    fe_Object *out = NULL;
    int rc = kec_eval_string(S, src, &out);
    CHECK(rc == 0, "evaluation failed");
    CHECK(out != NULL, "evaluation returned no value");
    if (rc != 0 || !out || fe_type(kec_fe(S), out) != FE_TNUMBER) { return -1; }
    return (int)fe_tonumber(kec_fe(S), out);
}

static void test_contexts_keep_independent_runtime_and_rng_state(void) {
    kec_State *a = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    kec_State *b = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    int a1, a2, b1, b2;

    CHECK(a != NULL && b != NULL, "two contexts did not open");
    if (!a || !b) { kec_close(a); kec_close(b); return; }

    eval_int(a, "(set-seed! 42)");
    eval_int(b, "(set-seed! 42)");
    a1 = eval_int(a, "(rand-int 1000)");
    b1 = eval_int(b, "(rand-int 1000)");
    a2 = eval_int(a, "(rand-int 1000)");
    b2 = eval_int(b, "(rand-int 1000)");
    CHECK(a1 == b1 && a2 == b2, "RNG sequence leaked between contexts");

    CHECK(eval_int(a, "(if (error? (try (fn () (raise \"a\")))) 1 0)") == 1,
          "first context did not recover its own error");
    CHECK(eval_int(b, "(if (error? (try (fn () (raise \"b\")))) 1 0)") == 1,
          "second context did not recover its own error");

    kec_close(a);
    kec_close(b);
}

static int g_alloc_a, g_free_a, g_alloc_b, g_free_b;

static void *alloc_a(size_t n) { g_alloc_a++; return malloc(n); }
static void free_a(void *p) { g_free_a++; free(p); }
static void *alloc_b(size_t n) { g_alloc_b++; return malloc(n); }
static void free_b(void *p) { g_free_b++; free(p); }

static void test_containers_remember_their_allocator(void) {
    kec_State *S = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);

    CHECK(S != NULL, "context did not open for allocator test");
    if (!S) { return; }

    kec_set_container_allocator_for(S, alloc_a, free_a);
    CHECK(kec_eval_string(S, "(do (set held-a (vector 1 2 3))"
                             "    (set held-ma (make-matrix 2 2 'x)))", NULL) == 0,
          "allocator-A vector/matrix creation failed");
    kec_set_container_allocator_for(S, alloc_b, free_b);
    CHECK(kec_eval_string(S, "(do (set held-b (make-hash-table))"
                             "    (set held-bb (make-blob 8 255)))", NULL) == 0,
          "allocator-B hash/blob creation failed");
    kec_close(S);

    CHECK(g_alloc_a > 0 && g_alloc_b > 0, "custom allocators were not used");
    CHECK(g_free_a == g_alloc_a, "allocator-A objects used the wrong free callback");
    CHECK(g_free_b == g_alloc_b, "allocator-B objects used the wrong free callback");
}

static int g_foreign_marked, g_foreign_freed;
static const char g_foreign_tag;

static void foreign_mark(fe_Context *ctx, void *ptr) {
    (void)ctx;
    CHECK(ptr == (void *)&g_foreign_tag, "foreign mark received wrong pointer");
    g_foreign_marked++;
}

static void foreign_gc(fe_Context *ctx, void *ptr) {
    (void)ctx;
    CHECK(ptr == (void *)&g_foreign_tag, "foreign gc received wrong pointer");
    g_foreign_freed++;
}

static void test_foreign_pointer_handlers_compose_with_containers(void) {
    kec_State *S = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    fe_Context *ctx;
    fe_Object *sym, *ptr;

    CHECK(S != NULL, "context did not open for foreign pointer test");
    if (!S) { return; }
    ctx = kec_fe(S);
    CHECK(fe_register_ptr_type(ctx, &g_foreign_tag, foreign_mark, foreign_gc) == 0,
          "foreign pointer type registration failed");
    ptr = fe_ptr_typed(ctx, (void *)&g_foreign_tag, &g_foreign_tag);
    sym = fe_symbol(ctx, "held-foreign");
    fe_set(ctx, sym, ptr);

    CHECK(kec_eval_string(S,
          "(do (set held-container (vector (list 1 2 3)))"
          "    (let i 0) (while (< i 300000) (cons i i) (set i (+ i 1))))",
          NULL) == 0,
          "GC churn with mixed foreign pointers failed");
    CHECK(g_foreign_marked > 0, "foreign pointer mark handler did not run");
    CHECK(kec_eval_string(S, "(vector-ref held-container 0)", NULL) == 0,
          "container lifecycle was displaced by foreign pointer registration");

    kec_close(S);
    CHECK(g_foreign_freed == 1, "foreign pointer gc handler did not run exactly once");
}

static int g_leak_alloc, g_leak_free;
static void *leak_alloc(size_t n) { g_leak_alloc++; return malloc(n); }
static void leak_free(void *p) { g_leak_free++; free(p); }

/* Container construction under Fe-arena exhaustion must not leak backing
** memory: when the FE_TPTR allocation raises out-of-memory, the C backing
** either was never taken or is owned by the (collectable) pointer object.
** Regression: constructors allocated the backing FIRST, so the longjmp out
** of fe_ptr_typed leaked it — permanently, on a fixed-arena device that
** catches errors and keeps running. */
static void test_constructors_do_not_leak_backing_on_arena_exhaustion(void) {
    /* Probes of stepped read footprints so repeated attempts sweep every
    ** failure point — including "form read + call succeeded, the FE_TPTR
    ** allocation itself failed", the historical leak window. */
    static const char *probes[] = {
        "(make-vector 4)",
        "(do (make-vector 4))",
        "(do 1 (make-vector 4))",
        "(do 1 2 (make-vector 4))",
        "(do 1 2 3 (make-vector 4))",
        "(make-blob 4)",
        "(do (make-blob 4))",
        "(make-hash-table)",
        "(do (make-matrix 2 2))",
    };
    kec_State *S = kec_open(2u * 1024u * 1024u, KEC_PROFILE_FULL);
    int round, j;

    CHECK(S != NULL, "context did not open for leak test");
    if (!S) { return; }
    g_leak_alloc = 0;
    g_leak_free = 0;
    kec_set_container_allocator_for(S, leak_alloc, leak_free);

    /* Seed a few live containers, then saturate the arena: `keep` roots an
    ** ever-growing list until the allocator raises, so from here on every
    ** object allocation is fighting over the failed forms' recycled slots. */
    CHECK(kec_eval_string(S, "(set keep (list (vector 1 2) (make-blob 3)))",
                          NULL) == 0,
          "seed containers failed");
    CHECK(kec_eval_string(S, "(while 1 (set keep (cons 0 keep)))", NULL) != 0,
          "arena never exhausted");

    /* Hammer constructors at saturation. Failures are expected (and normal);
    ** what must not happen is a backing allocation with no matching free. */
    for (round = 0; round < 50; round++) {
        for (j = 0; j < (int)(sizeof probes / sizeof probes[0]); j++) {
            kec_eval_string(S, probes[j], NULL);
        }
    }

    CHECK(g_leak_alloc > 0, "leak probe never allocated a backing");
    kec_close(S); /* sweeps every live container */
    CHECK(g_leak_alloc == g_leak_free,
          "container backing leaked under arena exhaustion");
    if (g_leak_alloc != g_leak_free) {
        fprintf(stderr, "  (alloc=%d free=%d)\n", g_leak_alloc, g_leak_free);
    }
}

static void get_first_gensym(kec_State *S, char *buf, int n) {
    fe_Object *out = NULL;
    int rc = kec_eval_string(S, "(symbol->string (gensym))", &out);
    buf[0] = '\0';
    CHECK(rc == 0 && out != NULL, "gensym evaluation failed");
    if (rc == 0 && out) { fe_tostring(kec_fe(S), out, buf, n); }
}

/* gensym numbering is context-owned host state: a fresh context always starts
** from the same origin, regardless of how many gensyms other contexts burned.
** Regression: the counter was a process-global static, so context creation
** order leaked into symbol names (and thus into anything reproducible built
** from them). */
static void test_gensym_is_context_owned(void) {
    kec_State *a = kec_open(2u * 1024u * 1024u, KEC_PROFILE_FULL);
    kec_State *b;
    char ga[64], gb[64];

    CHECK(a != NULL, "context did not open for gensym test");
    if (!a) { return; }
    get_first_gensym(a, ga, sizeof ga);
    /* Burn a few more so a process-global counter would visibly advance. */
    kec_eval_string(a, "(do (gensym) (gensym) (gensym))", NULL);

    b = kec_open(2u * 1024u * 1024u, KEC_PROFILE_FULL);
    CHECK(b != NULL, "second context did not open for gensym test");
    if (b) {
        get_first_gensym(b, gb, sizeof gb);
        CHECK(strcmp(ga, gb) == 0, "gensym numbering leaked between contexts");
        kec_close(b);
    }
    kec_close(a);
}

/* (now) measures elapsed seconds since the CONTEXT opened, so single-precision
** fe_Number keeps sub-millisecond resolution for the life of a session. The
** raw CLOCK_MONOTONIC epoch (machine boot) would decay to ~62 ms steps after
** ten days of uptime. A fresh context must read near zero — the 60 s bound is
** generous slack for a stalled runner, while boot-epoch readings on any
** warmed-up machine sit orders of magnitude above it. */
static void test_now_is_measured_from_context_open(void) {
    kec_State *S = kec_open(2u * 1024u * 1024u, KEC_PROFILE_FULL);
    fe_Object *out = NULL;

    CHECK(S != NULL, "context did not open for now test");
    if (!S) { return; }
    CHECK(kec_eval_string(S, "(now)", &out) == 0 && out != NULL,
          "(now) evaluation failed");
    if (out && fe_type(kec_fe(S), out) == FE_TNUMBER) {
        double t = (double)fe_tonumber(kec_fe(S), out);
        CHECK(t >= 0.0 && t < 60.0, "(now) is not measured from context open");
    } else {
        CHECK(0, "(now) did not return a number");
    }
    kec_close(S);
}

/* (args) is context-owned host state, set per interpreter — the same
** ownership rule as the RNG and gensym counters (GWP-235/584). Regression:
** argv lived in process-global statics shared across every context. */
static void test_args_are_context_owned(void) {
    static char *argv_a[] = { (char *)"prog-a", (char *)"one" };
    static char *argv_b[] = { (char *)"prog-b" };
    kec_State *a = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    kec_State *b = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);

    CHECK(a != NULL && b != NULL, "two contexts did not open for args test");
    if (!a || !b) { kec_close(a); kec_close(b); return; }
    kec_set_args(a, 2, argv_a);
    kec_set_args(b, 1, argv_b);
    CHECK(eval_int(a, "(length (args))") == 2, "context A lost its own args");
    CHECK(eval_int(b, "(length (args))") == 1, "context B lost its own args");
    CHECK(eval_int(a, "(if (is (car (args)) \"prog-a\") 1 0)") == 1,
          "context A returned the wrong argv");
    kec_close(a);
    kec_close(b);

    /* A fresh context with no args set reads an empty list, not a stale
    ** process-global left over from an earlier context. */
    a = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);
    CHECK(a != NULL, "third context did not open for args test");
    if (a) {
        CHECK(eval_int(a, "(length (args))") == 0, "unset args were not empty");
        kec_close(a);
    }
}

/* (args) must not grow the GC stack per element (the h_apply / read-all
** idiom): ~2 stale roots per arg times 5000 args would overflow even the
** desktop 8192-slot GC stack, let alone the device's 256. */
static void test_args_do_not_grow_the_gc_stack(void) {
    enum { ARGS_N = 5000 };
    static char *argv[ARGS_N];
    kec_State *S = kec_open(8u * 1024u * 1024u, KEC_PROFILE_FULL);
    int i;

    CHECK(S != NULL, "context did not open for args GC test");
    if (!S) { return; }
    for (i = 0; i < ARGS_N; i++) { argv[i] = (char *)"a"; }
    kec_set_args(S, ARGS_N, argv);
    CHECK(eval_int(S, "(length (args))") == ARGS_N,
          "(args) with many arguments failed (GC stack overflow?)");
    kec_close(S);
}

static void test_read_string_has_no_fixed_input_ceiling(void) {
    static const char prefix[] = "(string-length (read-string \"\\\"";
    static const char suffix[] = "\\\"\"))";
    const size_t payload_len = 5000;
    size_t source_len = sizeof prefix - 1 + payload_len + sizeof suffix;
    char *source = malloc(source_len);
    kec_State *S = kec_open(4u * 1024u * 1024u, KEC_PROFILE_FULL);

    CHECK(source != NULL && S != NULL, "long read-string test setup failed");
    if (!source || !S) { free(source); kec_close(S); return; }
    memcpy(source, prefix, sizeof prefix - 1);
    memset(source + sizeof prefix - 1, 'x', payload_len);
    memcpy(source + sizeof prefix - 1 + payload_len, suffix, sizeof suffix);
    CHECK(eval_int(S, source) == (int)payload_len, "read-string clipped long input");
    free(source);
    kec_close(S);
}

int main(void) {
    test_contexts_keep_independent_runtime_and_rng_state();
    test_containers_remember_their_allocator();
    test_foreign_pointer_handlers_compose_with_containers();
    test_constructors_do_not_leak_backing_on_arena_exhaustion();
    test_gensym_is_context_owned();
    test_now_is_measured_from_context_open();
    test_args_are_context_owned();
    test_args_do_not_grow_the_gc_stack();
    test_read_string_has_no_fixed_input_ceiling();
    if (g_failures == 0) { printf("test_host_state: all checks passed\n"); }
    return g_failures;
}
