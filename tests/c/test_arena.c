/*
** test_arena.c — C-level conformance for the no-malloc arena entry point
** kec_open_with_arena (GWP-502).
**
** The KEC-Lisp `.lsp` conformance suite exercises the language; this target
** exercises the C embedding seam that the suite cannot reach: opening an
** interpreter on a caller-supplied buffer with no arena malloc, the
** too-small-buffer rejection contract, and that kec_close leaves a
** caller-owned buffer untouched.
**
** Exit code 0 = all assertions held; non-zero = a failure (the message is
** printed to stderr and CTest surfaces it).
*/
#include "kec.h"

#include <stdio.h>
#include <string.h>

/* A static (BSS) arena, sized generously past the Core-load floor. Static so
** the buffer's address is stable and we never put megabytes on the stack. */
static unsigned char g_arena[2u * 1024u * 1024u];

static int g_failures = 0;

#define CHECK(cond, msg)                                                        \
    do {                                                                        \
        if (!(cond)) {                                                          \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);   \
            g_failures++;                                                       \
        }                                                                       \
    } while (0)

/* Open on the caller-provided arena, eval a Core form, assert the result. */
static void test_open_with_arena_runs_core(void) {
    kec_State *S = kec_open_with_arena(g_arena, sizeof g_arena, KEC_PROFILE_FULL);
    fe_Object *out = NULL;
    char buf[64];

    CHECK(S != NULL, "kec_open_with_arena returned NULL on a 2MB buffer");
    if (!S) { return; }

    /* Core's `map` and `range` must be live — proves the prelude loaded into
    ** the supplied buffer. (map (fn (x) (* x x)) (range 1 4)) => (1 4 9). */
    CHECK(kec_eval_string(S, "(map (fn (x) (* x x)) (range 1 4))", &out) == 0,
          "eval of Core map/range form errored");
    CHECK(out != NULL, "eval produced no value");
    if (out) {
        fe_tostring(kec_fe(S), out, buf, (int)sizeof buf);
        CHECK(strcmp(buf, "(1 4 9)") == 0, "map/range result was not (1 4 9)");
    }

    kec_close(S);
}

/* A buffer too small to load Core must return NULL — cleanly, no crash.
** 90000 bytes is above fe_open's context floor (so fe_open itself is safe)
** but below the Core-load floor, so the Core-load guard rejects it. */
static void test_too_small_returns_null(void) {
    static unsigned char small[90000];
    kec_State *S = kec_open_with_arena(small, sizeof small, KEC_PROFILE_FULL);
    CHECK(S == NULL, "too-small buffer did not return NULL");
    if (S) { kec_close(S); }
}

/* A buffer below fe_open's own context floor must also return NULL rather
** than fault inside fe_open before any error handler exists. */
static void test_tiny_buffer_returns_null(void) {
    static unsigned char tiny[1024];
    kec_State *S = kec_open_with_arena(tiny, sizeof tiny, KEC_PROFILE_FULL);
    CHECK(S == NULL, "tiny buffer did not return NULL");
    if (S) { kec_close(S); }
}

/* kec_close must NOT free a caller-provided buffer: after closing, the same
** buffer can be handed back to kec_open_with_arena and used again. */
static void test_close_does_not_free_caller_arena(void) {
    kec_State *S1 = kec_open_with_arena(g_arena, sizeof g_arena, KEC_PROFILE_FULL);
    kec_State *S2;
    fe_Object *out = NULL;

    CHECK(S1 != NULL, "first open on caller arena failed");
    if (S1) { kec_close(S1); }

    /* Reuse the identical buffer — if kec_close had freed it this would be a
    ** use-after-free; instead it must open and run cleanly. */
    S2 = kec_open_with_arena(g_arena, sizeof g_arena, KEC_PROFILE_FULL);
    CHECK(S2 != NULL, "reopen on the same caller arena failed");
    if (S2) {
        CHECK(kec_eval_string(S2, "(+ 1 2)", &out) == 0 && out != NULL &&
                  (int)fe_tonumber(kec_fe(S2), out) == 3,
              "reused caller arena did not evaluate (+ 1 2) to 3");
        kec_close(S2);
    }
}

/* Buffers in the window just above fe_open's context floor but below what host
** registration + Core need must return NULL — never exit(). The earlier
** too-small test (90000 B) only exercises the Core-load guard, where host
** registration already succeeded; the failure that exit()ed is when host
** registration itself exhausts the arena, which happens just above the floor.
** Sweep that window plus a few larger undersized sizes; if any size exits,
** this process dies and CTest reports failure. */
static void test_undersized_never_exits(void) {
    static unsigned char pool[128u * 1024u];
    size_t floor = (size_t)fe_min_arena_bytes() + 64u * (size_t)fe_object_size();
    size_t sizes[8];
    size_t i;
    sizes[0] = floor;
    sizes[1] = floor + 256u;
    sizes[2] = floor + 1024u;
    sizes[3] = floor + 2048u;
    sizes[4] = floor + 8192u;
    sizes[5] = 72u * 1024u;
    sizes[6] = 80u * 1024u;
    sizes[7] = 95u * 1024u;
    for (i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        kec_State *S = kec_open_with_arena(pool, sizes[i], KEC_PROFILE_SANDBOX);
        CHECK(S == NULL, "undersized arena did not return NULL cleanly");
        if (S) { kec_close(S); }
    }
}

/* Helper: is `name` bound to a cfunc in this context? An unbound global
** symbol evaluates to nil (type :nil), a bound host primitive to :cfunc — so
** (type-of NAME) discriminates "primitive present" from "absent" without the
** eval erroring. */
static int bound_as_cfunc(kec_State *S, const char *name) {
    char expr[64];
    char buf[16];
    fe_Object *out = NULL;
    snprintf(expr, sizeof expr, "(type-of %s)", name);
    if (kec_eval_string(S, expr, &out) != 0 || out == NULL) { return 0; }
    fe_tostring(kec_fe(S), out, buf, (int)sizeof buf);
    return strcmp(buf, ":cfunc") == 0;
}

/* Profile gating (GWP-529/530): the file/sys/env primitives must be bound in a
** FULL context and absent from a SANDBOX one. This is the cart-sandbox boundary
** — a SANDBOX context must not be able to touch the filesystem or environment. */
static void test_profile_gating(void) {
    static const char *gated[] = {
        "read-file", "write-file", "append-file", "file-exists?", "list-dir",
        "getenv", "args", "exit", "load"
    };
    static const char *removed[] = { "slurp", "spit", "spit-append" };
    static const char *always[] = { "str", "string-length" };
    size_t i;

    kec_State *full = kec_open_with_arena(g_arena, sizeof g_arena, KEC_PROFILE_FULL);
    CHECK(full != NULL, "FULL open failed");
    if (full) {
        for (i = 0; i < sizeof gated / sizeof gated[0]; i++) {
            CHECK(bound_as_cfunc(full, gated[i]),
                  "FULL profile is missing a gated primitive");
        }
        for (i = 0; i < sizeof removed / sizeof removed[0]; i++) {
            CHECK(!bound_as_cfunc(full, removed[i]),
                  "FULL profile still exposes a removed file primitive");
        }
        kec_close(full);
    }

    {
        kec_State *sand =
            kec_open_with_arena(g_arena, sizeof g_arena, KEC_PROFILE_SANDBOX);
        CHECK(sand != NULL, "SANDBOX open failed");
        if (sand) {
            for (i = 0; i < sizeof gated / sizeof gated[0]; i++) {
                CHECK(!bound_as_cfunc(sand, gated[i]),
                      "SANDBOX profile leaked a file/sys/env primitive");
            }
            /* The always-available primitives must still be present in SANDBOX. */
            for (i = 0; i < sizeof always / sizeof always[0]; i++) {
                /* str is a Core fn (not a cfunc); the rest are cfuncs. Just
                ** assert they evaluate to a non-nil type. */
                char expr[64], buf[16];
                fe_Object *out = NULL;
                snprintf(expr, sizeof expr, "(type-of %s)", always[i]);
                if (kec_eval_string(sand, expr, &out) == 0 && out) {
                    fe_tostring(kec_fe(sand), out, buf, (int)sizeof buf);
                    CHECK(strcmp(buf, ":nil") != 0,
                          "SANDBOX is missing an always-available primitive");
                }
            }
            kec_close(sand);
        }
    }
}

int main(void) {
    test_open_with_arena_runs_core();
    test_too_small_returns_null();
    test_tiny_buffer_returns_null();
    test_undersized_never_exits();
    test_close_does_not_free_caller_arena();
    test_profile_gating();

    if (g_failures == 0) {
        printf("test_arena: all checks passed\n");
    }
    return g_failures;
}
