/*
** kec.c — KEC Lisp runtime: arena + Fe context lifecycle, error recovery,
** KEC Core injection, and the two kec-level primitives `load` and `try`.
**
** Error model: every C-side failure routes through fe_error. Fe's default
** handler prints a traceback and exit()s; we replace it with a
** longjmp back to the nearest active guard so a script error recovers into
** the REPL / runner instead of killing the process.
*/
#include "kec.h"

#include <setjmp.h>
#include <stdlib.h>
#include <string.h>

#include "kec_core_embed.h" /* generated: static const char KEC_CORE_SRC[] */

#define KEC_GUARD_MAX 32

struct kec_State {
    fe_Context *ctx;
    void *arena;
    kec_Profile profile;
    char errmsg[256];
    int had_error;
    jmp_buf recover[KEC_GUARD_MAX];
    int depth; /* number of active guards */
};

/* Single-threaded interpreter: the error handler and the `try`/`load`
** primitives reach the live State through this. */
static kec_State *g_state = NULL;

/* ------------------------------------------------------------------ */
/* Error handler.                                                      */
/* ------------------------------------------------------------------ */

static void on_error(fe_Context *ctx, const char *err, fe_Object *cl) {
    kec_State *S = g_state;
    (void)ctx;
    (void)cl;
    if (S) {
        snprintf(S->errmsg, sizeof S->errmsg, "%s", err);
        S->had_error = 1;
        if (S->depth > 0) { longjmp(S->recover[S->depth - 1], 1); }
    }
    /* Unreachable in practice: every eval entry installs a guard. */
}

/* ------------------------------------------------------------------ */
/* Readers.                                                            */
/* ------------------------------------------------------------------ */

typedef struct { const char *s; size_t i; } StrReader;

static char str_readfn(fe_Context *ctx, void *udata) {
    StrReader *r = udata;
    (void)ctx;
    return r->s[r->i] ? r->s[r->i++] : '\0';
}

static char file_readfn(fe_Context *ctx, void *udata) {
    int c = fgetc((FILE *)udata);
    (void)ctx;
    return c == EOF ? '\0' : (char)c;
}

/* ------------------------------------------------------------------ */
/* Guarded top-level evaluation loop.                                  */
/* ------------------------------------------------------------------ */

static int run_forms(kec_State *S, fe_ReadFn rfn, void *ud, fe_Object **out) {
    fe_Context *ctx = S->ctx;
    int slot = S->depth;
    int base = fe_savegc(ctx);
    fe_Object *last = fe_bool(ctx, 0); /* nil */

    S->errmsg[0] = '\0';
    S->had_error = 0;
    if (slot >= KEC_GUARD_MAX) {
        snprintf(S->errmsg, sizeof S->errmsg, "guard stack overflow");
        return 1;
    }
    if (setjmp(S->recover[slot])) {
        S->depth = slot;
        fe_restoregc(ctx, base);
        if (out) { *out = fe_bool(ctx, 0); }
        return 1;
    }
    S->depth = slot + 1;
    for (;;) {
        fe_Object *form;
        fe_restoregc(ctx, base);
        fe_pushgc(ctx, last); /* keep prior value alive across the reset */
        form = fe_read(ctx, rfn, ud);
        if (form == NULL) { break; } /* EOF */
        last = fe_eval(ctx, form);
    }
    S->depth = slot;
    if (out) { *out = last; }
    return 0;
}

/* ------------------------------------------------------------------ */
/* kec-level primitives.                                               */
/* ------------------------------------------------------------------ */

/* (load path) — read + eval a file in the current context. FULL profile. */
static fe_Object *h_load(fe_Context *ctx, fe_Object *args) {
    char path[1024];
    FILE *fp;
    fe_tostring(ctx, fe_nextarg(ctx, &args), path, sizeof path);
    fp = fopen(path, "rb");
    if (!fp) { fe_error(ctx, "load: cannot open file"); }
    for (;;) {
        int gc = fe_savegc(ctx);
        fe_Object *form = fe_readfp(ctx, fp);
        if (form == NULL) { break; }
        fe_eval(ctx, form);
        fe_restoregc(ctx, gc);
    }
    fclose(fp);
    return fe_bool(ctx, 0);
}

/* (try thunk) — call (thunk); return its value, or :error if it raised. */
static fe_Object *h_try(fe_Context *ctx, fe_Object *args) {
    fe_Object *thunk = fe_nextarg(ctx, &args);
    kec_State *S = g_state;
    int slot = S->depth;
    int gc = fe_savegc(ctx);
    if (slot >= KEC_GUARD_MAX) { fe_error(ctx, "try: nesting too deep"); }
    if (setjmp(S->recover[slot])) {
        S->depth = slot;
        fe_restoregc(ctx, gc);
        return fe_symbol(ctx, ":error");
    }
    S->depth = slot + 1;
    {
        fe_Object *r = fe_eval(ctx, fe_cons(ctx, thunk, fe_bool(ctx, 0)));
        S->depth = slot;
        return r;
    }
}

/* ------------------------------------------------------------------ */
/* Public API.                                                         */
/* ------------------------------------------------------------------ */

kec_State *kec_open(size_t arena_bytes, kec_Profile profile) {
    kec_State *S = calloc(1, sizeof *S);
    if (!S) { return NULL; }
    S->arena = malloc(arena_bytes);
    if (!S->arena) { free(S); return NULL; }
    S->ctx = fe_open(S->arena, (int)arena_bytes);
    S->profile = profile;
    S->depth = 0;

    g_state = S;
    fe_handlers(S->ctx)->error = on_error;

    /* Host primitives must be bound before Core loads — Core's predicates and
    ** string ops call type-of / mod / gensym / string-*. */
    kec_host_register(S->ctx, profile);
    kec_bind_fe(S->ctx, "try", h_try);
    if (profile == KEC_PROFILE_FULL) { kec_bind_fe(S->ctx, "load", h_load); }

    /* Load Core (the standard library, written in KEC Lisp). */
    {
        StrReader r = { KEC_CORE_SRC, 0 };
        if (run_forms(S, str_readfn, &r, NULL) != 0) {
            /* If Core fails to load it's a bug in Core — surface it rather than
            ** running on a broken prelude. */
            fprintf(stderr, "kec: KEC Core failed to load: %s\n", S->errmsg);
            kec_close(S);
            return NULL;
        }
    }
    return S;
}

void kec_close(kec_State *S) {
    if (!S) { return; }
    if (S->ctx) { fe_close(S->ctx); }
    free(S->arena);
    if (g_state == S) { g_state = NULL; }
    free(S);
}

fe_Context *kec_fe(kec_State *S) { return S->ctx; }

int kec_eval_string(kec_State *S, const char *src, fe_Object **out) {
    StrReader r = { src, 0 };
    return run_forms(S, str_readfn, &r, out);
}

int kec_eval_file(kec_State *S, const char *path, fe_Object **out) {
    FILE *fp = fopen(path, "rb");
    int rc;
    if (!fp) {
        snprintf(S->errmsg, sizeof S->errmsg, "cannot open file: %s", path);
        return 1;
    }
    rc = run_forms(S, file_readfn, fp, out);
    fclose(fp);
    return rc;
}

int kec_check_string(kec_State *S, const char *src) {
    fe_Context *ctx = S->ctx;
    StrReader r = { src, 0 };
    int slot = S->depth;
    int base = fe_savegc(ctx);
    S->errmsg[0] = '\0';
    if (slot >= KEC_GUARD_MAX) {
        snprintf(S->errmsg, sizeof S->errmsg, "guard stack overflow");
        return 1;
    }
    if (setjmp(S->recover[slot])) {
        S->depth = slot;
        fe_restoregc(ctx, base);
        return 1;
    }
    S->depth = slot + 1;
    for (;;) {
        fe_Object *form;
        fe_restoregc(ctx, base);
        form = fe_read(ctx, str_readfn, &r);
        if (form == NULL) { break; }
    }
    S->depth = slot;
    return 0;
}

const char *kec_error(kec_State *S) { return S->errmsg; }

int kec_global_int(kec_State *S, const char *name, int dflt) {
    fe_Object *v = NULL;
    if (kec_eval_string(S, name, &v) != 0 || v == NULL) { return dflt; }
    if (fe_type(S->ctx, v) != FE_TNUMBER) { return dflt; }
    return (int)fe_tonumber(S->ctx, v);
}
