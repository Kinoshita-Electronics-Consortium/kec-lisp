/*
** kec.c — KEC Lisp runtime: arena + Fe context lifecycle, error recovery,
** KEC Core injection, and the kec-level primitives `load`, `try`, `raise`,
** and `macroexpand-1`.
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
    kec_HostState host;
    void *arena;
    int owns_arena; /* 1 if kec malloc'd the arena and must free it */
    kec_Profile profile;
    char errmsg[256];
    int had_error;
    jmp_buf recover[KEC_GUARD_MAX];
    int depth; /* number of active guards */
};

/* ------------------------------------------------------------------ */
/* Error handler.                                                      */
/* ------------------------------------------------------------------ */

static void on_error(fe_Context *ctx, const char *err, fe_Object *cl) {
    kec_State *S = fe_userdata(ctx, 0);
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

static int string_list_has(fe_Context *ctx, fe_Object *xs, const char *needle) {
    char buf[1024];
    while (!fe_isnil(ctx, xs)) {
        fe_tostring(ctx, fe_car(ctx, xs), buf, sizeof buf);
        if (strcmp(buf, needle) == 0) { return 1; }
        xs = fe_cdr(ctx, xs);
    }
    return 0;
}

static fe_Object *global_value(fe_Context *ctx, const char *name) {
    return fe_eval(ctx, fe_symbol(ctx, name));
}

static int global_string_list_has(fe_Context *ctx, const char *global, const char *needle) {
    return string_list_has(ctx, global_value(ctx, global), needle);
}

static void global_string_list_add(fe_Context *ctx, const char *global, const char *value) {
    int gc = fe_savegc(ctx);
    fe_Object *sym = fe_symbol(ctx, global);
    fe_Object *xs = fe_eval(ctx, sym);
    fe_Object *next;
    if (string_list_has(ctx, xs, value)) {
        fe_restoregc(ctx, gc);
        return;
    }
    next = fe_cons(ctx, fe_string(ctx, value), xs);
    fe_set(ctx, sym, next);
    fe_restoregc(ctx, gc);
}

static void eval_file_or_error(fe_Context *ctx, const char *path, const char *who) {
    FILE *fp = fopen(path, "rb");
    char msg[128];
    if (!fp) {
        snprintf(msg, sizeof msg, "%s: cannot open file", who);
        fe_error(ctx, msg);
    }
    for (;;) {
        int gc = fe_savegc(ctx);
        fe_Object *form = fe_readfp(ctx, fp);
        if (form == NULL) { break; }
        fe_eval(ctx, form);
        fe_restoregc(ctx, gc);
    }
    fclose(fp);
}

/* (load path) — read + eval a file in the current context. FULL profile. */
static fe_Object *h_load(fe_Context *ctx, fe_Object *args) {
    char path[1024];
    fe_tostring(ctx, fe_nextarg(ctx, &args), path, sizeof path);
    eval_file_or_error(ctx, path, "load");
    return fe_bool(ctx, 0);
}

static fe_Object *h_provide(fe_Context *ctx, fe_Object *args) {
    fe_Object *feature = fe_nextarg(ctx, &args);
    char name[1024];
    fe_tostring(ctx, feature, name, sizeof name);
    global_string_list_add(ctx, "%provided", name);
    return feature;
}

static fe_Object *h_provided_p(fe_Context *ctx, fe_Object *args) {
    char name[1024];
    fe_tostring(ctx, fe_nextarg(ctx, &args), name, sizeof name);
    return fe_bool(ctx, global_string_list_has(ctx, "%provided", name));
}

/* (require key [path]) — load once, by feature key. If path is omitted, key's
** printed name is used as the path. FULL profile only because it evaluates a
** file. Files may call (provide key), but require also records the key after a
** successful load so plain scripts are still loaded once. */
static fe_Object *h_require(fe_Context *ctx, fe_Object *args) {
    fe_Object *feature = fe_nextarg(ctx, &args);
    char key[1024], path[1024];
    fe_tostring(ctx, feature, key, sizeof key);
    if (!fe_isnil(ctx, args)) {
        fe_tostring(ctx, fe_nextarg(ctx, &args), path, sizeof path);
    } else {
        snprintf(path, sizeof path, "%s", key);
    }
    if (global_string_list_has(ctx, "%provided", key) ||
        global_string_list_has(ctx, "%required", key)) {
        return feature;
    }
    eval_file_or_error(ctx, path, "require");
    global_string_list_add(ctx, "%required", key);
    return feature;
}

/* (apply f arglist) — call f with the elements of arglist as its arguments.
**
** Built at the Lisp level, not by patching the frozen kernel: we synthesize the
** call form (f (quote a1) (quote a2) ...) and fe_eval it. Quoting each element
** makes the already-evaluated argument values pass through unevaluated, and
** putting the function object itself in operator position works because eval of
** a non-symbol / non-pair returns it as-is — so f may be a cfunc, a closure, or
** a kernel primitive uniformly. No kernel change required. */
static fe_Object *h_apply(fe_Context *ctx, fe_Object *args) {
    fe_Object *fn = fe_nextarg(ctx, &args);
    fe_Object *arglist = fe_nextarg(ctx, &args);
    fe_Object *quote = fe_symbol(ctx, "quote");
    fe_Object *nil = fe_bool(ctx, 0);
    fe_Object *rev = nil;   /* quoted args, reversed */
    fe_Object *call = nil;  /* the final (fn (quote a1) ...) form */
    int gc = fe_savegc(ctx);

    /* Pass 1: build the quoted-arg list, reversed. cons grows at the head, so
    ** no cdr mutation is needed (fe.h exposes no public setcdr). */
    fe_pushgc(ctx, rev);
    while (!fe_isnil(ctx, arglist)) {
        /* (quote elem) keeps the already-evaluated value from re-evaluating. */
        fe_Object *q = fe_cons(ctx, quote,
                               fe_cons(ctx, fe_nextarg(ctx, &arglist), nil));
        rev = fe_cons(ctx, q, rev);
        fe_restoregc(ctx, gc);
        fe_pushgc(ctx, rev);
    }
    /* Pass 2: reverse rev back to source order, then cons fn on the front.
    ** Result: (fn (quote a1) (quote a2) ...). Putting the function object itself
    ** in operator position works because eval of a non-symbol / non-pair returns
    ** it as-is — so fn may be a cfunc, a closure, or a kernel primitive. */
    while (!fe_isnil(ctx, rev)) {
        call = fe_cons(ctx, fe_car(ctx, rev), call);
        rev = fe_cdr(ctx, rev);
    }
    call = fe_cons(ctx, fn, call);
    {
        fe_Object *res = fe_eval(ctx, call);
        fe_restoregc(ctx, gc);
        fe_pushgc(ctx, res);
        return res;
    }
}

/* (read-string s) — parse the FIRST s-expression of s and return it, WITHOUT
** evaluating it. Pure reader, available in any profile: it hands back the parsed
** datum, nothing runs. To then evaluate it, use `eval` (a FULL-tier capability,
** so SANDBOX contexts can read forms without being able to run them). Empty /
** blank input -> nil. */
static fe_Object *h_read_string(fe_Context *ctx, fe_Object *args) {
    char buf[4096];
    StrReader r;
    fe_Object *form;
    fe_tostring(ctx, fe_nextarg(ctx, &args), buf, sizeof buf);
    r.s = buf;
    r.i = 0;
    form = fe_read(ctx, str_readfn, &r);
    if (form == NULL) { return fe_bool(ctx, 0); } /* EOF -> nil */
    return form;
}

/* (eval form) — evaluate an already-read data form in the live image and
** return its value. The keystone the editor model (nEmacs) needs: evaluate a
** form read from a buffer (eval-defun), a scratch-REPL line, or config-as-code.
** Pairs with read-string: (eval (read-string s)) reads and runs one form.
** fe_eval runs in the global environment, so defs/sets land as top-level
** bindings. FULL-tier only (bound beside `load`) — the deliberate "no eval in
** the sandbox" stance is preserved by *not* binding it into SANDBOX contexts. */
static fe_Object *h_eval(fe_Context *ctx, fe_Object *args) {
    return fe_eval(ctx, fe_nextarg(ctx, &args));
}

/* Counting / filling writers for the length-aware string dup below. */
static void count_writefn(fe_Context *ctx, void *udata, char chr) {
    (void)ctx; (void)chr;
    (*(size_t *)udata)++;
}
typedef struct { char *p; size_t n, cap; } FillBuf;
static void fill_writefn(fe_Context *ctx, void *udata, char chr) {
    FillBuf *b = udata;
    (void)ctx;
    if (b->n < b->cap) { b->p[b->n++] = chr; }
}

/* (read-all s) — parse EVERY top-level form of s and return them as a list, in
** source order (comments/whitespace skipped). The multi-form companion to
** read-string: (for-each eval (read-all src)) runs a whole config string. Like
** read-string it only reads — nothing is evaluated. Empty/blank input -> nil.
** Length-aware (no 4 KB clip; GWP-528 stance). */
static fe_Object *h_read_all(fe_Context *ctx, fe_Object *args) {
    fe_Object *src = fe_nextarg(ctx, &args);
    size_t len = 0;
    char *buf;
    StrReader r;
    fe_Object *form, *rev, *res;
    int gc;
    FillBuf b;

    fe_write(ctx, src, count_writefn, &len, 0);   /* measure */
    buf = malloc(len + 1);
    if (!buf) { fe_error(ctx, "read-all: out of memory"); }
    b.p = buf; b.n = 0; b.cap = len;
    fe_write(ctx, src, fill_writefn, &b, 0);      /* fill */
    buf[b.n] = '\0';

    /* Pass 1: read forms, accumulating reversed (cons grows at the head). */
    r.s = buf; r.i = 0;
    rev = fe_bool(ctx, 0); /* nil */
    gc = fe_savegc(ctx);
    fe_pushgc(ctx, rev);
    while ((form = fe_read(ctx, str_readfn, &r)) != NULL) {
        rev = fe_cons(ctx, form, rev);
        fe_restoregc(ctx, gc);
        fe_pushgc(ctx, rev);
    }
    free(buf);

    /* Pass 2: reverse into source order. rev stays rooted (reachable via the
    ** pushed head); each new res cons is rooted before the next allocation. */
    res = fe_bool(ctx, 0);
    fe_pushgc(ctx, res);
    while (!fe_isnil(ctx, rev)) {
        res = fe_cons(ctx, fe_car(ctx, rev), res);
        fe_pushgc(ctx, res);
        rev = fe_cdr(ctx, rev);
    }
    return res;
}

/* (macroexpand-1 form) — expand one symbolic macro call, or return form. */
static fe_Object *h_macroexpand_1(fe_Context *ctx, fe_Object *args) {
    return fe_macroexpand1(ctx, fe_nextarg(ctx, &args));
}

/* (raise message) — raise a catchable script-level error. */
static fe_Object *h_raise(fe_Context *ctx, fe_Object *args) {
    char msg[256];
    fe_tostring(ctx, fe_nextarg(ctx, &args), msg, sizeof msg);
    fe_error(ctx, msg);
    return fe_bool(ctx, 0);
}

/* (try thunk) — call (thunk); return its value, or, if it raised, the pair
** (:error . "message") — car is the :error symbol (so failure stays recognizable
** via (car r)) and cdr is the message the error handler captured in S->errmsg
** (GWP-532). check-err in the test harness keys off the :error car. */
static fe_Object *h_try(fe_Context *ctx, fe_Object *args) {
    fe_Object *thunk = fe_nextarg(ctx, &args);
    kec_State *S = fe_userdata(ctx, 0);
    int slot = S->depth;
    int gc = fe_savegc(ctx);
    if (slot >= KEC_GUARD_MAX) { fe_error(ctx, "try: nesting too deep"); }
    if (setjmp(S->recover[slot])) {
        S->depth = slot;
        fe_restoregc(ctx, gc);
        /* errmsg was just set by on_error before it longjmp'd here. */
        return fe_cons(ctx, fe_symbol(ctx, ":error"), fe_string(ctx, S->errmsg));
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

kec_State *kec_open_with_arena(void *buf, size_t size, kec_Profile profile) {
    kec_State *S;
    size_t floor;
    if (!buf) { return NULL; }

    /* Reject a buffer too small to even survive fe_open. fe_open subtracts its
    ** context header off the front, then registers ~30 primitives; a buffer
    ** below the header floor (plus a small object margin for registration)
    ** would fault inside fe_open before our error handler is installed — so we
    ** must reject it here, not catch it there. Above this floor, an
    ** insufficient arena fails cleanly later via the Core-load guard. */
    floor = (size_t)fe_min_arena_bytes() + 64u * (size_t)fe_object_size();
    if (size < floor) { return NULL; }

    S = calloc(1, sizeof *S);
    if (!S) { return NULL; }
    S->arena = buf;
    S->owns_arena = 0; /* caller owns the buffer; kec_close never frees it */
    S->ctx = fe_open(buf, (int)size);
    S->profile = profile;
    S->depth = 0;

    fe_set_userdata(S->ctx, 0, S);
    kec_host_state_init(&S->host);
    kec_host_attach_state(S->ctx, &S->host);
    fe_handlers(S->ctx)->error = on_error;

    /* Guard the whole setup. Both host registration and Core load allocate, and
    ** on a too-small arena Fe raises out-of-memory; without a guard here the
    ** host-registration phase runs with no handler frame and Fe's default path
    ** exit()s the process. Install a guard at slot 0 so any failure during
    ** setup — host bind or Core load — returns NULL cleanly instead. */
    if (setjmp(S->recover[0])) {
        kec_close(S);
        return NULL;
    }
    S->depth = 1;

    /* Host primitives must be bound before Core loads — Core's predicates and
    ** string ops call type-of / mod / gensym / string-*. */
    kec_host_register(S->ctx, profile);
    kec_bind_fe(S->ctx, "try", h_try);
    kec_bind_fe(S->ctx, "raise", h_raise);
    kec_bind_fe(S->ctx, "apply", h_apply);
    kec_bind_fe(S->ctx, "read-string", h_read_string);
    kec_bind_fe(S->ctx, "read-all", h_read_all);
    kec_bind_fe(S->ctx, "macroexpand-1", h_macroexpand_1);
    kec_bind_fe(S->ctx, "provide", h_provide);
    kec_bind_fe(S->ctx, "provided?", h_provided_p);
    if (profile == KEC_PROFILE_FULL) {
        kec_bind_fe(S->ctx, "load", h_load);
        kec_bind_fe(S->ctx, "require", h_require);
        /* eval is a FULL/editor-REPL-tier capability — it evaluates arbitrary
        ** constructed forms, so the deliberate "no eval in the sandbox" stance
        ** is kept by binding it only here, alongside load (see docs/builtins). */
        kec_bind_fe(S->ctx, "eval", h_eval);
    }

    /* Load Core (the standard library, written in KEC Lisp). A failure here
    ** usually means the arena is too small to hold the prelude; surface it and
    ** return NULL, freeing only what we own (never a caller-provided buffer). */
    {
        StrReader r = { KEC_CORE_SRC, 0 };
        if (run_forms(S, str_readfn, &r, NULL) != 0) {
            fprintf(stderr, "kec: KEC Core failed to load: %s\n", S->errmsg);
            kec_close(S);
            return NULL;
        }
    }
    S->depth = 0; /* setup complete — drop the setup guard */
    return S;
}

kec_State *kec_open(size_t arena_bytes, kec_Profile profile) {
    void *arena = malloc(arena_bytes);
    kec_State *S;
    if (!arena) { return NULL; }
    S = kec_open_with_arena(arena, arena_bytes, profile);
    if (!S) {
        /* kec_open_with_arena does not own the buffer, so it left ours intact
        ** on failure — free it here since kec_open is the owner. */
        free(arena);
        return NULL;
    }
    S->owns_arena = 1; /* kec_open malloc'd it; kec_close frees it */
    return S;
}

void kec_close(kec_State *S) {
    if (!S) { return; }
    if (S->ctx) { fe_close(S->ctx); }
    if (S->owns_arena) { free(S->arena); }
    free(S);
}

void kec_set_container_allocator_for(kec_State *S,
                                     void *(*alloc)(size_t),
                                     void (*free_)(void *)) {
    if (!S) { return; }
    kec_host_state_set_container_allocator(&S->host, alloc, free_);
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
