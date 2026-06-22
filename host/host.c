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
#define KEC_HOST_STATE_SLOT 1
#define KEC_RNG_DEFAULT 0x9E3779B97F4A7C15ULL

void kec_host_state_init(kec_HostState *state) {
    state->rng_state = KEC_RNG_DEFAULT;
    kec_host_state_set_container_allocator(state, NULL, NULL);
}

void kec_host_attach_state(fe_Context *ctx, kec_HostState *state) {
    fe_set_userdata(ctx, KEC_HOST_STATE_SLOT, state);
}

kec_HostState *kec_host_state(fe_Context *ctx) {
    kec_HostState *state = fe_userdata(ctx, KEC_HOST_STATE_SLOT);
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

/* Pull the next arg as a C string into a caller buffer; returns length.
** For the short, bounded conversions (a number's radix form, a path). The
** length-aware helpers below replace this for arbitrary user strings. */
static int arg_str(fe_Context *ctx, fe_Object **args, char *buf, int size) {
    return fe_tostring(ctx, fe_nextarg(ctx, args), buf, size);
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
static size_t host_strlen_qt(fe_Context *ctx, fe_Object *obj, int qt) {
    size_t n = 0;
    fe_write(ctx, obj, count_writefn, &n, qt);
    return n;
}
#define host_strlen(ctx, obj) host_strlen_qt((ctx), (obj), 0)

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
static char *host_strdup_qt(fe_Context *ctx, fe_Object *obj, int qt, size_t *len_out) {
    size_t len = host_strlen_qt(ctx, obj, qt);
    char *buf = malloc(len + 1);
    FillBuf b;
    if (!buf) { return NULL; }
    b.p = buf; b.n = 0; b.cap = len;
    fe_write(ctx, obj, fill_writefn, &b, qt);
    buf[b.n] = '\0';
    if (len_out) { *len_out = b.n; }
    return buf;
}
#define host_strdup_obj(ctx, obj, len_out) host_strdup_qt((ctx), (obj), 0, (len_out))

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

/* Fresh symbol for macro hygiene: %g0, %g1, ... (the %g prefix is reserved). */
static fe_Object *h_gensym(fe_Context *ctx, fe_Object *args) {
    static unsigned long counter = 0;
    char buf[32];
    (void)args;
    snprintf(buf, sizeof buf, "%%g%lu", counter++);
    return fe_symbol(ctx, buf);
}

/* (bound? sym) -> truthy if sym has a non-nil global binding, else nil. Reads
** the binding the way evaluation would (a plain lookup, no side effect). nil is
** absence in this Lisp, so a symbol bound to nil reads as unbound. Errors if the
** argument isn't a symbol. Read-only — safe in any profile (AMOP "fair use"). */
static fe_Object *h_bound_p(fe_Context *ctx, fe_Object *args) {
    fe_Object *sym = fe_nextarg(ctx, &args);
    if (fe_type(ctx, sym) != FE_TSYMBOL) { fe_error(ctx, "bound?: expected a symbol"); }
    return fe_bool(ctx, !fe_isnil(ctx, fe_eval(ctx, sym)));
}

/* (globals) / (globals prefix) -> a FRESH list of the interned symbols that
** have a non-nil global binding, optionally filtered to those whose name starts
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
        if (fe_isnil(ctx, fe_eval(ctx, sym))) { continue; } /* unbound */
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
        fe_pushgc(ctx, head);
        rest = copy_spine(ctx, fe_cdr(ctx, lst));
        fe_restoregc(ctx, gc);
        return fe_cons(ctx, head, rest);
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

static uint32_t arg_u32(fe_Context *ctx, fe_Object **args) {
    return (uint32_t)(int32_t)arg_num(ctx, args);
}

static fe_Object *h_bit_and(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args), b = arg_u32(ctx, &args);
    return fe_number(ctx, (fe_Number)(int32_t)(a & b));
}
static fe_Object *h_bit_or(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args), b = arg_u32(ctx, &args);
    return fe_number(ctx, (fe_Number)(int32_t)(a | b));
}
static fe_Object *h_bit_xor(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args), b = arg_u32(ctx, &args);
    return fe_number(ctx, (fe_Number)(int32_t)(a ^ b));
}
static fe_Object *h_bit_not(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args);
    return fe_number(ctx, (fe_Number)(int32_t)(~a));
}
static fe_Object *h_bit_shl(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args);
    uint32_t n = arg_u32(ctx, &args) & 31u;
    return fe_number(ctx, (fe_Number)(int32_t)(a << n));
}
static fe_Object *h_bit_shr(fe_Context *ctx, fe_Object *args) {
    uint32_t a = arg_u32(ctx, &args);
    uint32_t n = arg_u32(ctx, &args) & 31u; /* logical (zero-fill) shift */
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
    int i = (int)fe_tonumber(ctx, fe_nextarg(ctx, &args));
    size_t len;
    char *buf;
    fe_Object *res;
    if (i < 0) { return fe_bool(ctx, 0); }
    buf = host_strdup_obj(ctx, s, &len);
    if (!buf) { fe_error(ctx, "string-ref: out of memory"); }
    if ((size_t)i >= len) { free(buf); return fe_bool(ctx, 0); }
    res = fe_number(ctx, (fe_Number)(unsigned char)buf[i]);
    free(buf);
    return res;
}

static fe_Object *h_substring(fe_Context *ctx, fe_Object *args) {
    fe_Object *s = fe_nextarg(ctx, &args);
    int a = (int)fe_tonumber(ctx, fe_nextarg(ctx, &args));
    int b = (int)fe_tonumber(ctx, fe_nextarg(ctx, &args));
    size_t len;
    char *buf, save;
    fe_Object *res;
    buf = host_strdup_obj(ctx, s, &len);
    if (!buf) { fe_error(ctx, "substring: out of memory"); }
    if (a < 0) { a = 0; }
    if (b > (int)len) { b = (int)len; }
    if (b < a) { b = a; }
    /* fe_string copies up to the NUL; clip in place at b, slice from a. */
    save = buf[b];
    buf[b] = '\0';
    res = fe_string(ctx, buf + a);
    buf[b] = save;
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
    res = fe_string(ctx, out);
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
    fe_Object *res;
    if (!h) { fe_error(ctx, "string-search: out of memory"); }
    n = host_strdup_obj(ctx, needle, &nlen);
    if (!n) { free(h); fe_error(ctx, "string-search: out of memory"); }
    found = strstr(h, n);
    res = found ? fe_number(ctx, (fe_Number)(found - h)) : fe_bool(ctx, 0);
    free(h);
    free(n);
    return res;
}

static fe_Object *h_char_to_string(fe_Context *ctx, fe_Object *args) {
    char out[2];
    out[0] = (char)(int)fe_tonumber(ctx, fe_nextarg(ctx, &args));
    out[1] = '\0';
    return fe_string(ctx, out);
}

static fe_Object *h_number_to_string(fe_Context *ctx, fe_Object *args) {
    fe_Number n = arg_num(ctx, &args);
    int radix = 10;
    char buf[72];
    if (!fe_isnil(ctx, args)) { radix = (int)fe_tonumber(ctx, fe_nextarg(ctx, &args)); }
    if (radix == 10) {
        snprintf(buf, sizeof buf, "%.7g", (double)n);
    } else {
        const char *digits = "0123456789abcdef";
        char tmp[72];
        long v = (long)n;
        int neg = v < 0, ti = 0, bi = 0;
        unsigned long uv = neg ? (unsigned long)(-(v)) : (unsigned long)v;
        if (radix < 2 || radix > 16) { radix = 10; }
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
    arg_str(ctx, &args, buf, sizeof buf);
    v = strtod(buf, &end);
    if (end == buf) { return fe_bool(ctx, 0); } /* unparseable -> nil */
    return fe_number(ctx, (fe_Number)v);
}

static fe_Object *h_symbol_to_string(fe_Context *ctx, fe_Object *args) {
    char buf[KEC_STRBUF];
    arg_str(ctx, &args, buf, sizeof buf);
    return fe_string(ctx, buf);
}

static fe_Object *h_string_to_symbol(fe_Context *ctx, fe_Object *args) {
    char buf[KEC_STRBUF];
    arg_str(ctx, &args, buf, sizeof buf);
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
    char *buf = host_strdup_qt(ctx, fe_nextarg(ctx, &args), 1, NULL);
    fe_Object *res;
    if (!buf) { fe_error(ctx, "repr: out of memory"); }
    res = fe_string(ctx, buf);
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
** The state is a single 64-bit word, initialized to a fixed nonzero default
** so an unseeded `rand` is still deterministic across runs. */
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
    fe_Number n = arg_num(ctx, &args);
    kec_host_state(ctx)->rng_state = (uint64_t)(int64_t)n;
    return fe_number(ctx, n);
}

static fe_Object *h_rand(fe_Context *ctx, fe_Object *args) {
    /* Top 53 bits -> a double in [0,1), then narrowed to fe_Number. */
    (void)args;
    return fe_number(ctx, (fe_Number)((double)(rng_next(ctx) >> 11) *
                                      (1.0 / 9007199254740992.0)));
}
static fe_Object *h_rand_int(fe_Context *ctx, fe_Object *args) {
    int n = (int)fe_tonumber(ctx, fe_nextarg(ctx, &args));
    if (n <= 0) { return fe_number(ctx, 0); }
    return fe_number(ctx, (fe_Number)(uint32_t)((rng_next(ctx) >> 16) % (uint64_t)n));
}
static fe_Object *h_clock(fe_Context *ctx, fe_Object *args) {
    (void)args;
    return fe_number(ctx, (fe_Number)((double)clock() / CLOCKS_PER_SEC));
}

/* ------------------ FULL-profile only (file / sys) ----------------- */

static char **g_argv = NULL;
static int g_argc = 0;

void kec_host_set_args(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
}

static fe_Object *h_args(fe_Context *ctx, fe_Object *args) {
    fe_Object *res = fe_bool(ctx, 0); /* nil */
    int i;
    (void)args;
    for (i = g_argc - 1; i >= 0; i--) {
        res = fe_cons(ctx, fe_string(ctx, g_argv[i]), res);
    }
    return res;
}

static fe_Object *h_read_file(fe_Context *ctx, fe_Object *args) {
    char path[KEC_STRBUF];
    FILE *fp;
    long len;
    char *body;
    fe_Object *res;
    arg_str(ctx, &args, path, sizeof path);
    fp = fopen(path, "rb");
    if (!fp) { fe_error(ctx, "read-file: cannot open file"); }
    fseek(fp, 0, SEEK_END);
    len = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    body = malloc((size_t)len + 1);
    if (!body) { fclose(fp); fe_error(ctx, "read-file: out of memory"); }
    if (fread(body, 1, (size_t)len, fp) != (size_t)len) { /* short read tolerated */ }
    body[len] = '\0';
    fclose(fp);
    res = fe_string(ctx, body);
    free(body);
    return res;
}

/* (write-file path value) / (append-file path value) — write value to a file.
** The value is stringified the writer's way (raw, like princ / str), so any
** value works, not just strings. Length-aware so writes past the old 4 KB
** ceiling are byte-exact (GWP-528/529). Failures route through fe_error
** (catchable by try); never exit(). FULL profile only. */
static fe_Object *h_write_file_mode(fe_Context *ctx, fe_Object *args, const char *mode,
                                    const char *name) {
    char path[KEC_STRBUF];
    fe_Object *val;
    size_t len;
    char *body;
    FILE *fp;
    size_t wrote;
    arg_str(ctx, &args, path, sizeof path);
    val = fe_nextarg(ctx, &args);
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

/* (file-exists? path) -> truthy if path exists (any type), else nil. */
static fe_Object *h_file_exists(fe_Context *ctx, fe_Object *args) {
    char path[KEC_STRBUF];
    struct stat st;
    arg_str(ctx, &args, path, sizeof path);
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
    arg_str(ctx, &args, path, sizeof path);
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
    arg_str(ctx, &args, name, sizeof name);
    v = getenv(name);
    if (!v) { return fe_bool(ctx, 0); } /* unset -> nil */
    return fe_string(ctx, v);
}

static fe_Object *h_exit(fe_Context *ctx, fe_Object *args) {
    int code = 0;
    if (!fe_isnil(ctx, args)) { code = (int)fe_tonumber(ctx, fe_nextarg(ctx, &args)); }
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
    /* Containers (vectors + hash tables) — portable, safe in any profile.
    ** Also installs the FE_TPTR mark/gc handlers (see host/containers.c). */
    kec_containers_register(ctx);

    if (profile == KEC_PROFILE_FULL) {
        kec_bind_fe(ctx, "args", h_args);
        kec_bind_fe(ctx, "read-file", h_read_file);
        kec_bind_fe(ctx, "write-file", h_write_file);
        kec_bind_fe(ctx, "append-file", h_append_file);
        kec_bind_fe(ctx, "file-exists?", h_file_exists);
        kec_bind_fe(ctx, "list-dir", h_list_dir);
        kec_bind_fe(ctx, "getenv", h_getenv);
        kec_bind_fe(ctx, "exit", h_exit);
    }
}
