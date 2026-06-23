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
    test_read_string_has_no_fixed_input_ceiling();
    if (g_failures == 0) { printf("test_host_state: all checks passed\n"); }
    return g_failures;
}
