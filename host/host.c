/*
** host.c — KEC Lisp's portable C primitives.
**
** Every primitive here needs only the C library, not KN-86 hardware. The
** firmware adds its device primitives through the same kec_bind_fe seam; see
** docs/ffi-bridge.md.
**
** C name `h_foo`  ->  KEC Lisp symbol `foo-bar` (kebab-case). The Lisp name is
** what callers use; the C name is internal.
*/
#define _POSIX_C_SOURCE 200809L /* scandir / alphasort / stat / struct dirent */

#include "host.h"

#include <dirent.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

/* Scratch buffer for the *short, bounded* conversions (number radix, single
** char). The string primitives below do NOT use this: they size to the real
** string length so nothing past ~4 KB is silently truncated (GWP-528). */
#define KEC_STRBUF 4096
#define KEC_RNG_DEFAULT 0x9E3779B97F4A7C15ULL

static const char g_host_state_tag;

static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

void kec_host_state_init(kec_HostState *state) {
    state->rng_state = KEC_RNG_DEFAULT;
    state->gensym_counter = 0;
    state->now_base = monotonic_seconds();
    state->pending_count = 0;
    state->argv = NULL;
    state->argc = 0;
    kec_host_state_set_container_allocator(state, NULL, NULL);
}

void kec_host_state_set_args(kec_HostState *state, int argc, char **argv) {
    state->argc = (argv && argc > 0) ? argc : 0;
    state->argv = argv;
}

/* --- Error-path leak guard (host.h) ------------------------------- */

void kec_pending_push(fe_Context *ctx, void *p) {
    kec_HostState *state = kec_host_state(ctx);
    if (state->pending_count >= KEC_PENDING_MAX) {
        free(p);
        fe_error(ctx, "internal: pending-buffer registry overflow");
    }
    state->pending[state->pending_count++] = p;
}

void kec_pending_pop(fe_Context *ctx, void *p) {
    kec_HostState *state = kec_host_state(ctx);
    int i;
    for (i = state->pending_count - 1; i >= 0; i--) {
        if (state->pending[i] == p) {
            memmove(&state->pending[i], &state->pending[i + 1],
                    (size_t)(state->pending_count - 1 - i) * sizeof state->pending[0]);
            state->pending_count--;
            return;
        }
    }
}

void kec_host_state_free_pending(kec_HostState *state) {
    while (state->pending_count > 0) {
        free(state->pending[--state->pending_count]);
    }
}

void kec_host_attach_state(fe_Context *ctx, kec_HostState *state) {
    fe_set_userdata(ctx, &g_host_state_tag, state);
}

kec_HostState *kec_host_state(fe_Context *ctx) {
    kec_HostState *state = fe_userdata(ctx, &g_host_state_tag);
    if (!state) { fe_error(ctx, "host state is not attached"); }
    return state;
}

/* ------------------------------------------------------------------ */
/* The bind seam — GC-safe symbol→cfunc registration.                  */
/* ------------------------------------------------------------------ */

void kec_bind_fe(fe_Context *ctx, const char *name, fe_CFunc fn) {
    int gc = fe_savegc(ctx);
    fe_Object *sym = fe_symbol(ctx, name);
    fe_Object *cf = fe_cfunc(ctx, fn);
    fe_set(ctx, sym, cf);
    fe_restoregc(ctx, gc);
}

/* ------------------------------------------------------------------ */
/* Small helpers.                                                      */
/* ------------------------------------------------------------------ */

static fe_Number arg_num(fe_Context *ctx, fe_Object **args) {
    return fe_tonumber(ctx, fe_nextarg(ctx, args));
}

int32_t kec_checked_int(fe_Context *ctx, fe_Object **args, const char *who) {
    double n = (double)arg_num(ctx, args);
    char msg[96];
    if (!isfinite(n) || floor(n) != n || n < (double)INT32_MIN || n > (double)INT32_MAX) {
        snprintf(msg, sizeof msg, "%s: expected an integer", who);
        fe_error(ctx, msg);
    }
    return (int32_t)n;
}

int kec_checked_byte(fe_Context *ctx, fe_Object **args, const char *who) {
    int n = (int)kec_checked_int(ctx, args, who);
    char msg[96];
    if (n < 0 || n > 255) {
        snprintf(msg, sizeof msg, "%s: expected byte 0..255", who);
        fe_error(ctx, msg);
    }
    return n;
}

/* Pull the next arg as a C string into a caller buffer; returns length.
** For the short, bounded conversions (a number's radix form, a prefix). The
** length-aware helpers below replace this for arbitrary user strings. */
static int arg_str(fe_Context *ctx, fe_Object **args, char *buf, int size) {
    return fe_tostring(ctx, fe_nextarg(ctx, args), buf, size);
}

/* As arg_str, but raise a catchable "<who>: <what> too long" when the printed
** form does not fit, instead of silently truncating. A clipped path names a
** DIFFERENT file — (write-file longpath ...) would clobber the wrong target —
** and truncate-then-parse misreads string->number / string->symbol input. */
static int arg_str_bounded(fe_Context *ctx, fe_Object **args, char *buf, int size,
                           const char *who, const char *what) {
    fe_Object *v = fe_nextarg(ctx, args);
    if (kec_strlen_obj(ctx, v, 0) >= (size_t)size) {
        char msg[96];
        snprintf(msg, sizeof msg, "%s: %s too long", who, what);
        fe_error(ctx, msg);
    }
    return fe_tostring(ctx, v, buf, size);
}

/* ------------------------------------------------------------------ */
/* Length-aware stringify (GWP-528).                                   */
/*                                                                     */
/* fe_tostring copies into a caller-fixed buffer and truncates at      */
/* size-1, so any value whose printed form is longer was silently      */
/* clipped — the old 4 KB ceiling. fe_write streams every byte through */
/* a callback with no limit, so we measure first, then fill a buffer   */
/* sized to the real length. Heap-backed: a glyph string is small, but */
/* nothing here imposes a ceiling.                                     */
/* ------------------------------------------------------------------ */

/* Counting writer: discards bytes, just tallies them. */
static void count_writefn(fe_Context *ctx, void *udata, char chr) {
    (void)ctx;
    (void)chr;
    (*(size_t *)udata)++;
}

/* Exact printed length of obj in bytes — no allocation. `qt` selects quoted
** (write-style) vs raw (princ-style) rendering, matching fe_write. */
size_t kec_strlen_obj(fe_Context *ctx, fe_Object *obj, int qt) {
    size_t n = 0;
    fe_write(ctx, obj, count_writefn, &n, qt);
    return n;
}
#define host_strlen(ctx, obj) kec_strlen_obj((ctx), (obj), 0)

/* Filling writer: append into a FillBuf with a hard capacity guard. */
typedef struct { char *p; size_t n, cap; } FillBuf;
static void fill_writefn(fe_Context *ctx, void *udata, char chr) {
    FillBuf *b = udata;
    (void)ctx;
    if (b->n < b->cap) { b->p[b->n++] = chr; }
}

/* Stringify obj into a freshly malloc'd, NUL-terminated buffer sized to the
** real length. `qt` selects quoted vs raw. *len_out (if non-NULL) receives the
** byte length. Returns NULL only on OOM; callers route that through fe_error.
** The buffer is the caller's to free(). */
char *kec_strdup_obj(fe_Context *ctx, fe_Object *obj, int qt, size_t *len_out) {
    size_t len = kec_strlen_obj(ctx, obj, qt);
    char *buf = malloc(len + 1);
    FillBuf b;
    if (!buf) { return NULL; }
    b.p = buf; b.n = 0; b.cap = len;
    fe_write(ctx, obj, fill_writefn, &b, qt);
    buf[b.n] = '\0';
    if (len_out) { *len_out = b.n; }
    return buf;
}
#define host_strdup_obj(ctx, obj, len_out) kec_strdup_obj((ctx), (obj), 0, (len_out))

/* ------------------------------------------------------------------ */
/* Reflection — type-of, which Core's number?/string?/etc. need.       */
/* ------------------------------------------------------------------ */

static fe_Object *h_type_of(fe_Context *ctx, fe_Object *args) {
    fe_Object *x = fe_nextarg(ctx, &args);
    const char *t;
    switch (fe_type(ctx, x)) {
        case FE_TPAIR:   t = ":pair";   break;
        case FE_TNIL:    t = ":nil";    break;
        case FE_TNUMBER: t = ":number"; break;
        case FE_TSYMBOL: t = ":symbol"; break;
        case FE_TSTRING: t = ":string"; break;
        case FE_TFUNC:   t = ":fn";     break;
        case FE_TMACRO:  t = ":macro";  break;
        case FE_TPRIM:   t = ":prim";   break;
        case FE_TCFUNC:  t = ":cfunc";  break;
        case FE_TPTR:    t = ":ptr";    break;
        default:         t = ":unknown"; break;
    }
    return fe_symbol(ctx, t);
}

/* Fresh symbol for macro hygiene: %g0, %g1, ... (the %g prefix is reserved).
** The counter is context-owned host state, not a process global, so a fresh
** context always numbers from the same origin — symbol names stay reproducible
** no matter how many contexts came before it in the process. */
static fe_Object *h_gensym(fe_Context *ctx, fe_Object *args) {
    char buf[32];
    (void)args;
    snprintf(buf, sizeof buf, "%%g%lu", kec_host_state(ctx)->gensym_counter++);
    return fe_symbol(ctx, buf);
}

/* (bound? sym) -> truthy if sym has a global binding, including a binding whose
** value is nil. Errors if the argument isn't a symbol. Read-only — safe in any
** profile (AMOP "fair use"). */
static fe_Object *h_bound_p(fe_Context *ctx, fe_Object *args) {
    fe_Object *sym = fe_nextarg(ctx, &args);
    if (fe_type(ctx, sym) != FE_TSYMBOL) { fe_error(ctx, "bound?: expected a symbol"); }
    return fe_bool(ctx, fe_bound(ctx, sym));
}

/* (globals) / (globals prefix) -> a FRESH list of the interned symbols that
** have a global binding, optionally filtered to those whose name starts
** with `prefix`. Order is unspecified. The list is the caller's to keep; the
** symbols are interned singletons (their identity is the public contract), but
** the runtime never hands out its internal symbol list (AMOP "fair use rules"):
** we build a new list here. Read-only — safe in any profile. */
static fe_Object *h_globals(fe_Context *ctx, fe_Object *args) {
    char prefix[KEC_STRBUF];
    char name[KEC_STRBUF];
    int has_prefix = 0;
    size_t plen = 0;
    fe_Object *res, *p;
    int gc;
    if (!fe_isnil(ctx, args)) {
        plen = (size_t)arg_str(ctx, &args, prefix, sizeof prefix);
        has_prefix = 1;
    }
    res = fe_bool(ctx, 0); /* nil */
    gc = fe_savegc(ctx);
    for (p = fe_symbols(ctx); !fe_isnil(ctx, p); p = fe_cdr(ctx, p)) {
        fe_Object *sym = fe_car(ctx, p);
        if (!fe_bound(ctx, sym)) { continue; }
        if (has_prefix) {
            fe_tostring(ctx, sym, name, sizeof name);
            if (strncmp(name, prefix, plen) != 0) { continue; }
        }
        res = fe_cons(ctx, sym, res);
        /* Keep only the growing result rooted across the GC reset (see h_list_dir). */
        fe_restoregc(ctx, gc);
        fe_pushgc(ctx, res);
    }
    return res;
}

/* Fresh copy of a parameter list's spine. A proper or dotted list is copied
** cons-by-cons (the final non-nil tail is preserved); a non-pair (nil, or a
** variadic single-symbol param list) is returned as-is. Recursion depth is the
** parameter count — tiny. Fair-use: the caller can't reach the closure through
** the returned list. */
static fe_Object *copy_spine(fe_Context *ctx, fe_Object *lst) {
    if (fe_type(ctx, lst) != FE_TPAIR) { return lst; }
    {
        int gc = fe_savegc(ctx);
        fe_Object *head = fe_car(ctx, lst);
        fe_Object *rest;
        fe_Object *out;
        fe_pushgc(ctx, head);
        rest = copy_spine(ctx, fe_cdr(ctx, lst));
        /* cons BEFORE dropping the roots: rest is a fresh spine reachable from
        ** nothing else, and fe_cons may collect. Re-push the result so each
        ** level hands its caller a rooted object (net one slot per level). */
        out = fe_cons(ctx, head, rest);
        fe_restoregc(ctx, gc);
        fe_pushgc(ctx, out);
        return out;
    }
}

/* (fn-params f) -> the parameter list of a Lisp closure or macro (a fresh copy,
** fair-use), nil for a built-in cfunc/prim (no Lisp parameters), or an error if
** f is not a function. Feeds describe-function-style help. Read-only — safe in
** any profile. */
static fe_Object *h_fn_params(fe_Context *ctx, fe_Object *args) {
    fe_Object *fn = fe_nextarg(ctx, &args);
    int t = fe_type(ctx, fn);
    if (t != FE_TFUNC && t != FE_TMACRO && t != FE_TCFUNC && t != FE_TPRIM) {
        fe_error(ctx, "fn-params: not a function");
    }
    return copy_spine(ctx, fe_fn_params(ctx, fn));
}

/* ------------------------------------------------------------------ */
/* Math — the kernel ships only + - * / < <= ; these fill the gap.     */
/* ------------------------------------------------------------------ */

static fe_Object *h_mod(fe_Context *ctx, fe_Object *args) {
    fe_Number a = arg_num(ctx, &args), b = arg_num(ctx, &args);
    return fe_number(ctx, (fe_Number)fmod((double)a, (double)b));
}
static fe_Object *h_floor(fe_Context *ctx, fe_Object *args) {
    return fe_number(ctx, (fe_Number)floor((double)arg_num(ctx, &args)));
}
static fe_Object *h_ceil(fe_Context *ctx, fe_Object *args) {
    return fe_number(ctx, (fe_Number)ceil((double)arg_num(ctx, &args)));
}
static fe_Object *h_round(fe_Context *ctx, fe_Object *args) {
    return fe_number(ctx, (fe_Number)floor((double)arg_num(ctx, &args) + 0.5));
}
static fe_Object *h_abs(fe_Context *ctx, fe_Object *args) {
    return fe_number(ctx, (fe_Number)fabs((double)arg_num(ctx, &args)));
}
static fe_Object *h_sqrt(fe_Context *ctx, fe_Object *args) {
    return fe_number(ctx, (fe_Number)sqrt((double)arg_num(ctx, &args)));
}
static fe_Object *h_pow(fe_Context *ctx, fe_Object *args) {
    fe_Number a = arg_num(ctx, &args), b = arg_num(ctx, &args);
    return fe_number(ctx, (fe_Number)pow((double)a, (double)b));
}
/* Trig — radians (C convention). Computed in double, narrowed to fe_Number
** (single-precision float), so results carry ~1e-7 relative error: fine for
** geometry/CRT, unsafe for high-iteration accumulation. (pi/tau are Core
** constants — core/15-math.lsp — since kec_bind_fe registers cfuncs only.)
** atan2 takes (y x) like C and resolves the full -pi..pi range. */
static fe_Object *h_sin(fe_Context *ctx, fe_Object *args) {
    return fe_number(ctx, (fe_Number)sin((double)arg_num(ctx, &args)));
}
static fe_Object *h_cos(fe_Context *ctx, fe_Object *args) {
    return fe_number(ctx, (fe_Number)cos((double)arg_num(ctx, &args)));
}
static fe_Object *h_tan(fe_Context *ctx, fe_Object *args) {
    return fe_number(ctx, (fe_Number)tan((double)arg_num(ctx, &args)));
}
static fe_Object *h_atan2(fe_Context *ctx, fe_Object *args) {
    fe_Number y = arg_num(ctx, &args), x = arg_num(ctx, &args);
    return fe_number(ctx, (fe_Number)atan2((double)y, (double)x));
}

/* ------------------------------------------------------------------ */
/* Bitwise — packing/masking the kernel arithmetic primitives can't do.*/
/*                                                                     */
/* Operands are taken as numbers and forced through int32_t so a       */
/* negative fe_Number yields its two's-complement bit pattern (e.g.    */
/* (bit-and -1 255) -> 255). The logical work is done on uint32_t      */
/* (well-defined wrap, zero-fill shift), then the result is cast back  */
/* int32_t -> fe_Number, so values stay inside the exact-integer float */
/* window only up to +/-2^24 — wider results lose precision like any   */
/* other KEC number. (bit-shr is a LOGICAL right shift: it zero-fills  */
/* the high bits, it is not arithmetic.) Shift counts are masked & 31  */
/* to avoid shifting by >= the width (which is undefined in C).        */
/* ------------------------------------------------------------------ */

static uint32_t arg_u32(fe_Context *ctx, fe_Object **args, const char *who) {
    return (uint32_t)kec_checked_int(ctx, args, who);
}

static fe_Object *h_bit_and(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args, "bit-and"), b = arg_u32(ctx, &args, "bit-and");
    return fe_number(ctx, (fe_Number)(int32_t)(a & b));
}
static fe_Object *h_bit_or(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args, "bit-or"), b = arg_u32(ctx, &args, "bit-or");
    return fe_number(ctx, (fe_Number)(int32_t)(a | b));
}
static fe_Object *h_bit_xor(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args, "bit-xor"), b = arg_u32(ctx, &args, "bit-xor");
    return fe_number(ctx, (fe_Number)(int32_t)(a ^ b));
}
static fe_Object *h_bit_not(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args, "bit-not");
    return fe_number(ctx, (fe_Number)(int32_t)(~a));
}
static fe_Object *h_bit_shl(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args, "bit-shl");
    uint32_t n = arg_u32(ctx, &args, "bit-shl") & 31u;
    return fe_number(ctx, (fe_Number)(int32_t)(a << n));
}
static fe_Object *h_bit_shr(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args, "bit-shr");
    uint32_t n = arg_u32(ctx, &args, "bit-shr") & 31u; /* logical (zero-fill) shift */
    return fe_number(ctx, (fe_Number)(int32_t)(a >> n));
}

/* ------------------------------------------------------------------ */
/* Strings — char-level access the kernel can't express in Lisp.       */
/* ------------------------------------------------------------------ */

static fe_Object *h_string_length(fe_Context *ctx, fe_Object *args) {
    /* No allocation: just stream-count the bytes (GWP-528). */
    size_t n = host_strlen(ctx, fe_nextarg(ctx, &args));
    return fe_number(ctx, (fe_Number)n);
}

static fe_Object *h_string_ref(fe_Context *ctx, fe_Object *args) {
    fe_Object *s = fe_nextarg(ctx, &args);
    int i = (int)kec_checked_int(ctx, &args, "string-ref");
    size_t len;
    char *buf;
    fe_Object *res;
    if (i < 0) { return fe_bool(ctx, 0); }
    buf = host_strdup_obj(ctx, s, &len);
    if (!buf) { fe_error(ctx, "string-ref: out of memory"); }
    if ((size_t)i >= len) { free(buf); return fe_bool(ctx, 0); }
    {
        /* Take the byte and free BEFORE fe_number: an out-of-memory raise
        ** there would longjmp past the free. */
        unsigned char c = (unsigned char)buf[i];
        free(buf);
        res = fe_number(ctx, (fe_Number)c);
    }
    return res;
}

static fe_Object *h_substring(fe_Context *ctx, fe_Object *args) {
    fe_Object *s = fe_nextarg(ctx, &args);
    int a = (int)kec_checked_int(ctx, &args, "substring");
    int b = (int)kec_checked_int(ctx, &args, "substring");
    size_t len, lo, hi;
    char *buf, save;
    fe_Object *res;
    buf = host_strdup_obj(ctx, s, &len);
    if (!buf) { fe_error(ctx, "substring: out of memory"); }
    /* Clamp BOTH indices into [0, len] before touching the buffer: a start
    ** past the end used to survive unclamped and index buf out of bounds —
    ** a heap write through buf[b] (GWP-700). Clamping in size_t also drops
    ** the (int)len narrowing. */
    lo = a < 0 ? 0u : (size_t)a;
    hi = b < 0 ? 0u : (size_t)b;
    if (lo > len) { lo = len; }
    if (hi > len) { hi = len; }
    if (hi < lo) { hi = lo; }
    /* fe_string copies up to the NUL; clip in place at hi, slice from lo.
    ** The buffer is registered while fe_string can raise out-of-memory. */
    save = buf[hi];
    buf[hi] = '\0';
    kec_pending_push(ctx, buf);
    res = fe_string(ctx, buf + lo);
    kec_pending_pop(ctx, buf);
    buf[hi] = save;
    free(buf);
    return res;
}

/* Variadic concat. Each arg is stringified the same way the writer prints
** it (numbers via %.7g, symbols by name, strings raw) — so this doubles as
** the engine for Core `str`. Sized to the real total length (GWP-528): a
** single fe_write pass per arg into one buffer grown to fit, no 4 KB clip. */
static fe_Object *h_string_append(fe_Context *ctx, fe_Object *args) {
    /* Pass 1: measure the total length without allocating. */
    size_t total = 0;
    fe_Object *p = args;
    char *out;
    FillBuf b;
    fe_Object *res;
    while (!fe_isnil(ctx, p)) {
        total += host_strlen(ctx, fe_nextarg(ctx, &p));
    }
    out = malloc(total + 1);
    if (!out) { fe_error(ctx, "string-append: out of memory"); }
    /* Pass 2: fill. */
    b.p = out; b.n = 0; b.cap = total;
    while (!fe_isnil(ctx, args)) {
        fe_write(ctx, fe_nextarg(ctx, &args), fill_writefn, &b, 0);
    }
    out[b.n] = '\0';
    kec_pending_push(ctx, out); /* fe_string may raise out-of-memory */
    res = fe_string(ctx, out);
    kec_pending_pop(ctx, out);
    free(out);
    return res;
}

/* (string-search haystack needle) -> 0-based index of the first occurrence of
** needle in haystack, or nil if absent. An empty needle matches at 0. Both
** arguments are stringified length-aware (no 4 KB clip). */
static fe_Object *h_string_search(fe_Context *ctx, fe_Object *args) {
    fe_Object *hay = fe_nextarg(ctx, &args);
    fe_Object *needle = fe_nextarg(ctx, &args);
    size_t hlen, nlen;
    char *h = host_strdup_obj(ctx, hay, &hlen);
    char *n, *found;
    long idx;
    if (!h) { fe_error(ctx, "string-search: out of memory"); }
    n = host_strdup_obj(ctx, needle, &nlen);
    if (!n) { free(h); fe_error(ctx, "string-search: out of memory"); }
    found = strstr(h, n);
    /* Take the index and free BEFORE fe_number: an out-of-memory raise there
    ** would longjmp past the frees. */
    idx = found ? (long)(found - h) : -1;
    free(h);
    free(n);
    return idx >= 0 ? fe_number(ctx, (fe_Number)idx) : fe_bool(ctx, 0);
}

/* (string-split s sepcode) -> the substrings of s split on every occurrence of
** the byte `sepcode` (a char code, as string-ref returns). Always returns at
** least one element; N separators yield N+1 segments ("" -> ("") ; "a,b" ->
** ("a" "b") ; "a," -> ("a" "")). One O(n) pass over a single materialization of
** the string — the char-level sibling of string-ref. (Splitting in Lisp with
** (string-ref s i) per index is O(n^2): each call restringifies the whole
** object, so opening a large file used to hang for tens of seconds.)
**
** Built right-to-left so the segments cons up in source order with no reverse
** pass; the list-of-strings GC discipline mirrors h_list_dir (object() auto-roots
** each allocation, then restoregc/pushgc keeps just the growing list rooted). */
static fe_Object *h_string_split(fe_Context *ctx, fe_Object *args) {
    fe_Object *s = fe_nextarg(ctx, &args);
    int sep = kec_checked_byte(ctx, &args, "string-split");
    size_t len, end;
    long i;
    char *buf, save;
    fe_Object *res, *head;
    int gc;
    buf = host_strdup_obj(ctx, s, &len);
    if (!buf) { fe_error(ctx, "string-split: out of memory"); }
    /* Registered across the whole loop: every fe_string / fe_cons below can
    ** raise out-of-memory. */
    kec_pending_push(ctx, buf);
    res = fe_bool(ctx, 0);                 /* nil */
    gc = fe_savegc(ctx);
    fe_pushgc(ctx, res);
    end = len;                             /* exclusive end of the pending segment */
    for (i = (long)len - 1; i >= 0; i--) {
        if ((unsigned char)buf[i] == (unsigned char)sep) {
            save = buf[end]; buf[end] = '\0';            /* segment is buf[i+1 .. end) */
            head = fe_string(ctx, buf + i + 1);
            buf[end] = save;
            res = fe_cons(ctx, head, res);
            fe_restoregc(ctx, gc);
            fe_pushgc(ctx, res);
            end = (size_t)i;
        }
    }
    save = buf[end]; buf[end] = '\0';                    /* the leading segment buf[0 .. end) */
    head = fe_string(ctx, buf);
    buf[end] = save;
    res = fe_cons(ctx, head, res);
    fe_restoregc(ctx, gc);
    fe_pushgc(ctx, res);
    kec_pending_pop(ctx, buf);
    free(buf);
    return res;
}

static fe_Object *h_char_to_string(fe_Context *ctx, fe_Object *args) {
    char out[2];
    out[0] = (char)kec_checked_byte(ctx, &args, "char->string");
    out[1] = '\0';
    return fe_string(ctx, out);
}

static fe_Object *h_number_to_string(fe_Context *ctx, fe_Object *args) {
    fe_Number n = arg_num(ctx, &args);
    int radix = 10;
    char buf[72];
    if (!fe_isnil(ctx, args)) {
        radix = (int)kec_checked_int(ctx, &args, "number->string");
        if (radix < 2 || radix > 16) {
            fe_error(ctx, "number->string: radix must be 2..16");
        }
    }
    if (radix == 10) {
        snprintf(buf, sizeof buf, "%.7g", (double)n);
    } else {
        /* A non-decimal rendering is digit-exact, so the value must be an
        ** exact integer — the same finite/integral/int32 window every other
        ** integer-taking primitive enforces (no UB float->long cast). */
        const char *digits = "0123456789abcdef";
        char tmp[72];
        double d = (double)n;
        long v;
        int neg, ti = 0, bi = 0;
        unsigned long uv;
        if (!isfinite(d) || floor(d) != d ||
            d < (double)INT32_MIN || d > (double)INT32_MAX) {
            fe_error(ctx, "number->string: expected an integer value for radix 2..16");
        }
        v = (long)d;
        neg = v < 0;
        /* Magnitude in unsigned arithmetic: -(v) is signed-overflow UB for
        ** INT32_MIN where long is 32 bits (the armhf device target). */
        uv = neg ? (0UL - (unsigned long)v) : (unsigned long)v;
        if (uv == 0) { tmp[ti++] = '0'; }
        while (uv) { tmp[ti++] = digits[uv % (unsigned)radix]; uv /= (unsigned)radix; }
        if (neg) { buf[bi++] = '-'; }
        while (ti) { buf[bi++] = tmp[--ti]; }
        buf[bi] = '\0';
    }
    return fe_string(ctx, buf);
}

static fe_Object *h_string_to_number(fe_Context *ctx, fe_Object *args) {
    char buf[KEC_STRBUF], *end;
    double v;
    arg_str_bounded(ctx, &args, buf, sizeof buf, "string->number", "argument");
    v = strtod(buf, &end);
    if (end == buf) { return fe_bool(ctx, 0); } /* unparseable -> nil */
    /* Overflow to the float infinity of the sign BEFORE narrowing: converting
    ** a finite double beyond FLT_MAX to float is undefined in ISO C11
    ** (6.3.1.5) outside Annex F. The observable result stays inf (GWP-700). */
    if (v > (double)FLT_MAX) { v = (double)INFINITY; }
    else if (v < -(double)FLT_MAX) { v = -(double)INFINITY; }
    return fe_number(ctx, (fe_Number)v);
}

static fe_Object *h_symbol_to_string(fe_Context *ctx, fe_Object *args) {
    char buf[KEC_STRBUF];
    arg_str_bounded(ctx, &args, buf, sizeof buf, "symbol->string", "argument");
    return fe_string(ctx, buf);
}

static fe_Object *h_string_to_symbol(fe_Context *ctx, fe_Object *args) {
    char buf[KEC_STRBUF];
    arg_str_bounded(ctx, &args, buf, sizeof buf, "string->symbol", "argument");
    return fe_symbol(ctx, buf);
}

/* ------------------------------------------------------------------ */
/* I/O — kernel `print` exists; these give finer control.             */
/* ------------------------------------------------------------------ */

static fe_Object *h_princ(fe_Context *ctx, fe_Object *args) {
    while (!fe_isnil(ctx, args)) {
        fe_writefp(ctx, fe_nextarg(ctx, &args), stdout); /* raw, no quotes */
    }
    return fe_bool(ctx, 0);
}
static fe_Object *h_newline(fe_Context *ctx, fe_Object *args) {
    (void)args;
    fputc('\n', stdout);
    return fe_bool(ctx, 0);
}

/* repr: render a value the way `write` would (strings quoted). Used by the
** test harness to label a failing check with its source form. Length-aware
** (GWP-528) so a long form isn't clipped in the failure message. */
static fe_Object *h_repr(fe_Context *ctx, fe_Object *args) {
    char *buf = kec_strdup_obj(ctx, fe_nextarg(ctx, &args), 1, NULL);
    fe_Object *res;
    if (!buf) { fe_error(ctx, "repr: out of memory"); }
    kec_pending_push(ctx, buf); /* fe_string may raise out-of-memory */
    res = fe_string(ctx, buf);
    kec_pending_pop(ctx, buf);
    free(buf);
    return res;
}

/* ------------------------------------------------------------------ */
/* System.                                                            */
/* ------------------------------------------------------------------ */

/* Self-contained PRNG (SplitMix64). We deliberately do NOT use libc rand():
** its sequence differs across platforms, but the mission board generates
** contracts from deck-state-seeded templates, so reproducible procedural
** generation must be byte-identical on every host. A fixed seed therefore
** yields a fixed sequence everywhere — see tests/core/rng.lsp (golden value).
** Each interpreter owns one 64-bit state word, initialized to a fixed nonzero
** default so an unseeded `rand` is deterministic without leaking across
** contexts. */
static uint64_t rng_next(fe_Context *ctx) {
    kec_HostState *state = kec_host_state(ctx);
    uint64_t z = (state->rng_state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

/* (set-seed! n) — reseed the PRNG from n, returning n. Used so deck-state seeds
** make `rand`/`rand-int` reproducible. */
static fe_Object *h_set_seed(fe_Context *ctx, fe_Object *args) {
    int32_t n = kec_checked_int(ctx, &args, "set-seed!");
    kec_host_state(ctx)->rng_state = (uint64_t)(int64_t)n;
    return fe_number(ctx, (fe_Number)n);
}

static fe_Object *h_rand(fe_Context *ctx, fe_Object *args) {
    /* Top 53 bits -> a double in [0,1), then narrowed to fe_Number. */
    (void)args;
    return fe_number(ctx, (fe_Number)((double)(rng_next(ctx) >> 11) *
                                      (1.0 / 9007199254740992.0)));
}
static fe_Object *h_rand_int(fe_Context *ctx, fe_Object *args) {
    int32_t n = kec_checked_int(ctx, &args, "rand-int");
    /* [0, n) is empty for n <= 0 — raise instead of inventing a 0. */
    if (n <= 0) { fe_error(ctx, "rand-int: bound must be a positive integer"); }
    return fe_number(ctx, (fe_Number)(uint32_t)((rng_next(ctx) >> 16) % (uint64_t)n));
}
static fe_Object *h_clock(fe_Context *ctx, fe_Object *args) {
    (void)args;
    return fe_number(ctx, (fe_Number)((double)clock() / CLOCKS_PER_SEC));
}
/* (now) — monotonic elapsed seconds since THIS CONTEXT opened, distinct from
** (clock) which is CPU time. Use (now) for timers/animation/elapsed-time;
** (clock) for profiling. CLOCK_MONOTONIC never jumps backward and ignores
** wall-clock resets. The per-context baseline matters because fe_Number is a
** single-precision float: raw seconds-since-boot decay to ~62 ms resolution
** after ten days of uptime, while seconds-since-open keep sub-millisecond
** precision for the life of any session. */
static fe_Object *h_now(fe_Context *ctx, fe_Object *args) {
    (void)args;
    return fe_number(ctx, (fe_Number)(monotonic_seconds() -
                                      kec_host_state(ctx)->now_base));
}

/* ------------------ FULL-profile only (file / sys) ----------------- */

static fe_Object *h_args(fe_Context *ctx, fe_Object *args) {
    kec_HostState *state = kec_host_state(ctx);
    fe_Object *res = fe_bool(ctx, 0); /* nil */
    int i, gc = fe_savegc(ctx);
    (void)args;
    for (i = state->argc - 1; i >= 0; i--) {
        res = fe_cons(ctx, fe_string(ctx, state->argv[i]), res);
        /* Keep only the growing list rooted across the GC reset (see
        ** h_list_dir): without it each arg leaves ~2 stale roots, and ~100
        ** args overflow the device's 256-slot GC stack. */
        fe_restoregc(ctx, gc);
        fe_pushgc(ctx, res);
    }
    return res;
}

static fe_Object *h_read_file(fe_Context *ctx, fe_Object *args) {
    char path[KEC_STRBUF];
    FILE *fp;
    long len = 0; /* fe_error below never returns, but the compiler can't see
                  ** that through the ||: keep -Wsometimes-uninitialized quiet */
    char *body;
    fe_Object *res;
    arg_str_bounded(ctx, &args, path, sizeof path, "read-file", "path");
    fp = fopen(path, "rb");
    if (!fp) { fe_error(ctx, "read-file: cannot open file"); }
    /* ftell is -1 on a non-seekable stream (FIFO, /dev/stdin); feeding that
    ** into malloc/fread would write into a zero-byte buffer. */
    if (fseek(fp, 0, SEEK_END) != 0 || (len = ftell(fp)) < 0
        || fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        fe_error(ctx, "read-file: not a seekable file");
    }
    body = malloc((size_t)len + 1);
    if (!body) { fclose(fp); fe_error(ctx, "read-file: out of memory"); }
    if (fread(body, 1, (size_t)len, fp) != (size_t)len) { /* short read tolerated */ }
    body[len] = '\0';
    fclose(fp);
    kec_pending_push(ctx, body); /* fe_string may raise out-of-memory —
                                 ** the worst leak here is a whole file body */
    res = fe_string(ctx, body);
    kec_pending_pop(ctx, body);
    free(body);
    return res;
}

/* (write-file path value) / (append-file path value): write value to a file.
** A blob is written verbatim as raw bytes (binary-safe); any other value is
** stringified the writer's way (raw, like princ / str), so any value works,
** not just strings. Length-aware so writes past the old 4 KB ceiling are
** byte-exact (GWP-528/529). Failures route through fe_error (catchable by
** try); never exit(). FULL profile only. */
static fe_Object *h_write_file_mode(fe_Context *ctx, fe_Object *args, const char *mode,
                                    const char *name) {
    char path[KEC_STRBUF];
    fe_Object *val;
    size_t len;
    const unsigned char *blob;
    char *body;
    FILE *fp;
    size_t wrote;
    arg_str_bounded(ctx, &args, path, sizeof path, name, "path");
    val = fe_nextarg(ctx, &args);

    /* A blob writes its raw bytes verbatim: binary-safe (NUL and high bytes
    ** survive), with no stringify or malloc since the bytes are the blob's own
    ** storage. Every other value type keeps the writer's raw stringification. */
    if (kec_blob_bytes(ctx, val, &blob, &len)) {
        fp = fopen(path, mode);
        if (!fp) {
            char msg[96];
            snprintf(msg, sizeof msg, "%s: cannot open file for writing", name);
            fe_error(ctx, msg);
        }
        wrote = fwrite(blob, 1, len, fp);
        fclose(fp);
        if (wrote != len) {
            char msg[64];
            snprintf(msg, sizeof msg, "%s: short write", name);
            fe_error(ctx, msg);
        }
        return fe_bool(ctx, 1);
    }

    body = host_strdup_obj(ctx, val, &len);
    if (!body) {
        char msg[64];
        snprintf(msg, sizeof msg, "%s: out of memory", name);
        fe_error(ctx, msg);
    }
    fp = fopen(path, mode);
    if (!fp) {
        char msg[96];
        free(body);
        snprintf(msg, sizeof msg, "%s: cannot open file for writing", name);
        fe_error(ctx, msg);
    }
    wrote = fwrite(body, 1, len, fp);
    fclose(fp);
    free(body);
    if (wrote != len) {
        char msg[64];
        snprintf(msg, sizeof msg, "%s: short write", name);
        fe_error(ctx, msg);
    }
    return fe_bool(ctx, 1); /* truthy on success */
}

static fe_Object *h_write_file(fe_Context *ctx, fe_Object *args) {
    return h_write_file_mode(ctx, args, "wb", "write-file");
}

static fe_Object *h_append_file(fe_Context *ctx, fe_Object *args) {
    return h_write_file_mode(ctx, args, "ab", "append-file");
}

/* (read-blob path) -- read a file's raw bytes into a blob. Binary-safe: NUL and
** high bytes survive, unlike read-file, which returns a NUL-terminated string.
** Mirrors read-file's seekable-file and error handling. FULL profile only. */
static fe_Object *h_read_blob(fe_Context *ctx, fe_Object *args) {
    char path[KEC_STRBUF];
    FILE *fp;
    long len = 0; /* see h_read_file: defined for the || short-circuit path */
    unsigned char *body;
    fe_Object *res;
    arg_str_bounded(ctx, &args, path, sizeof path, "read-blob", "path");
    fp = fopen(path, "rb");
    if (!fp) { fe_error(ctx, "read-blob: cannot open file"); }
    if (fseek(fp, 0, SEEK_END) != 0 || (len = ftell(fp)) < 0
        || fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        fe_error(ctx, "read-blob: not a seekable file");
    }
    body = malloc((size_t)len > 0 ? (size_t)len : 1); /* never malloc(0) */
    if (!body) { fclose(fp); fe_error(ctx, "read-blob: out of memory"); }
    if (fread(body, 1, (size_t)len, fp) != (size_t)len) { /* short read tolerated */ }
    fclose(fp);
    kec_pending_push(ctx, body); /* kec_blob_from_bytes may raise (OOM/oversize) */
    res = kec_blob_from_bytes(ctx, body, (size_t)len);
    kec_pending_pop(ctx, body);
    free(body);
    return res;
}

/* (file-exists? path) -> truthy if path exists (any type), else nil. */
static fe_Object *h_file_exists(fe_Context *ctx, fe_Object *args) {
    char path[KEC_STRBUF];
    struct stat st;
    arg_str_bounded(ctx, &args, path, sizeof path, "file-exists?", "path");
    return fe_bool(ctx, stat(path, &st) == 0);
}

/* (list-dir path) -> list of entry names in path, excluding "." and "..".
** Errors (catchable) if the directory cannot be opened. Order is unspecified
** (we build the list in reverse of readdir order). */
static fe_Object *h_list_dir(fe_Context *ctx, fe_Object *args) {
    char path[KEC_STRBUF];
    DIR *d;
    struct dirent *e;
    fe_Object *res = fe_bool(ctx, 0); /* nil */
    int gc;
    arg_str_bounded(ctx, &args, path, sizeof path, "list-dir", "path");
    d = opendir(path);
    if (!d) { fe_error(ctx, "list-dir: cannot open directory"); }
    gc = fe_savegc(ctx);
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
            continue;
        }
        res = fe_cons(ctx, fe_string(ctx, e->d_name), res);
        /* Keep only the growing list rooted across the GC reset. */
        fe_restoregc(ctx, gc);
        fe_pushgc(ctx, res);
    }
    closedir(d);
    return res;
}

/* (getenv name) -> the environment variable's value as a string, or nil. */
static fe_Object *h_getenv(fe_Context *ctx, fe_Object *args) {
    char name[KEC_STRBUF];
    const char *v;
    arg_str_bounded(ctx, &args, name, sizeof name, "getenv", "name");
    v = getenv(name);
    if (!v) { return fe_bool(ctx, 0); } /* unset -> nil */
    return fe_string(ctx, v);
}

static fe_Object *h_exit(fe_Context *ctx, fe_Object *args) {
    int code = 0;
    if (!fe_isnil(ctx, args)) { code = (int)kec_checked_int(ctx, &args, "exit"); }
    exit(code);
    return fe_bool(ctx, 0); /* unreached */
}

/* ------------------------------------------------------------------ */
/* Registration.                                                       */
/* ------------------------------------------------------------------ */

void kec_host_register(fe_Context *ctx, kec_Profile profile) {
    /* Reflection (read-only — safe in any profile) */
    kec_bind_fe(ctx, "type-of", h_type_of);
    kec_bind_fe(ctx, "gensym", h_gensym);
    kec_bind_fe(ctx, "bound?", h_bound_p);
    kec_bind_fe(ctx, "globals", h_globals);
    kec_bind_fe(ctx, "fn-params", h_fn_params);
    /* Math */
    kec_bind_fe(ctx, "mod", h_mod);
    kec_bind_fe(ctx, "floor", h_floor);
    kec_bind_fe(ctx, "ceil", h_ceil);
    kec_bind_fe(ctx, "round", h_round);
    kec_bind_fe(ctx, "abs", h_abs);
    kec_bind_fe(ctx, "sqrt", h_sqrt);
    kec_bind_fe(ctx, "pow", h_pow);
    kec_bind_fe(ctx, "sin", h_sin);
    kec_bind_fe(ctx, "cos", h_cos);
    kec_bind_fe(ctx, "tan", h_tan);
    kec_bind_fe(ctx, "atan2", h_atan2);
    /* Bitwise (32-bit, logical shr) */
    kec_bind_fe(ctx, "bit-and", h_bit_and);
    kec_bind_fe(ctx, "bit-or", h_bit_or);
    kec_bind_fe(ctx, "bit-xor", h_bit_xor);
    kec_bind_fe(ctx, "bit-not", h_bit_not);
    kec_bind_fe(ctx, "bit-shl", h_bit_shl);
    kec_bind_fe(ctx, "bit-shr", h_bit_shr);
    /* Strings */
    kec_bind_fe(ctx, "string-length", h_string_length);
    kec_bind_fe(ctx, "string-ref", h_string_ref);
    kec_bind_fe(ctx, "substring", h_substring);
    kec_bind_fe(ctx, "string-append", h_string_append);
    kec_bind_fe(ctx, "string-search", h_string_search);
    kec_bind_fe(ctx, "string-split", h_string_split);
    kec_bind_fe(ctx, "char->string", h_char_to_string);
    kec_bind_fe(ctx, "number->string", h_number_to_string);
    kec_bind_fe(ctx, "string->number", h_string_to_number);
    kec_bind_fe(ctx, "symbol->string", h_symbol_to_string);
    kec_bind_fe(ctx, "string->symbol", h_string_to_symbol);
    /* I/O */
    kec_bind_fe(ctx, "princ", h_princ);
    kec_bind_fe(ctx, "newline", h_newline);
    kec_bind_fe(ctx, "repr", h_repr);
    /* System (portable, safe in any profile) */
    kec_bind_fe(ctx, "set-seed!", h_set_seed);
    kec_bind_fe(ctx, "rand", h_rand);
    kec_bind_fe(ctx, "rand-int", h_rand_int);
    kec_bind_fe(ctx, "clock", h_clock);
    kec_bind_fe(ctx, "now", h_now);
    /* Containers (vectors + hash tables) — portable, safe in any profile.
    ** Registers a composable typed-FE_TPTR lifecycle (see containers.c). */
    kec_containers_register(ctx);

    if (profile == KEC_PROFILE_FULL) {
        kec_bind_fe(ctx, "args", h_args);
        kec_bind_fe(ctx, "read-file", h_read_file);
        kec_bind_fe(ctx, "read-blob", h_read_blob);
        kec_bind_fe(ctx, "write-file", h_write_file);
        kec_bind_fe(ctx, "append-file", h_append_file);
        kec_bind_fe(ctx, "file-exists?", h_file_exists);
        kec_bind_fe(ctx, "list-dir", h_list_dir);
        kec_bind_fe(ctx, "getenv", h_getenv);
        kec_bind_fe(ctx, "exit", h_exit);
    }
}
