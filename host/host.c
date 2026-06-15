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
#include "host.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Scratch buffer for the *short, bounded* conversions (number radix, single
** char). The string primitives below do NOT use this: they size to the real
** string length so nothing past ~4 KB is silently truncated (GWP-528). */
#define KEC_STRBUF 4096

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

static fe_Object *h_rand(fe_Context *ctx, fe_Object *args) {
    (void)args;
    return fe_number(ctx, (fe_Number)((double)rand() / ((double)RAND_MAX + 1.0)));
}
static fe_Object *h_rand_int(fe_Context *ctx, fe_Object *args) {
    int n = (int)fe_tonumber(ctx, fe_nextarg(ctx, &args));
    if (n <= 0) { return fe_number(ctx, 0); }
    return fe_number(ctx, (fe_Number)(rand() % n));
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

static fe_Object *h_slurp(fe_Context *ctx, fe_Object *args) {
    char path[KEC_STRBUF];
    FILE *fp;
    long len;
    char *body;
    fe_Object *res;
    arg_str(ctx, &args, path, sizeof path);
    fp = fopen(path, "rb");
    if (!fp) { fe_error(ctx, "slurp: cannot open file"); }
    fseek(fp, 0, SEEK_END);
    len = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    body = malloc((size_t)len + 1);
    if (!body) { fclose(fp); fe_error(ctx, "slurp: out of memory"); }
    if (fread(body, 1, (size_t)len, fp) != (size_t)len) { /* short read tolerated */ }
    body[len] = '\0';
    fclose(fp);
    res = fe_string(ctx, body);
    free(body);
    return res;
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
    /* Reflection */
    kec_bind_fe(ctx, "type-of", h_type_of);
    kec_bind_fe(ctx, "gensym", h_gensym);
    /* Math */
    kec_bind_fe(ctx, "mod", h_mod);
    kec_bind_fe(ctx, "floor", h_floor);
    kec_bind_fe(ctx, "ceil", h_ceil);
    kec_bind_fe(ctx, "round", h_round);
    kec_bind_fe(ctx, "abs", h_abs);
    kec_bind_fe(ctx, "sqrt", h_sqrt);
    kec_bind_fe(ctx, "pow", h_pow);
    /* Strings */
    kec_bind_fe(ctx, "string-length", h_string_length);
    kec_bind_fe(ctx, "string-ref", h_string_ref);
    kec_bind_fe(ctx, "substring", h_substring);
    kec_bind_fe(ctx, "string-append", h_string_append);
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
    kec_bind_fe(ctx, "rand", h_rand);
    kec_bind_fe(ctx, "rand-int", h_rand_int);
    kec_bind_fe(ctx, "clock", h_clock);

    if (profile == KEC_PROFILE_FULL) {
        kec_bind_fe(ctx, "args", h_args);
        kec_bind_fe(ctx, "slurp", h_slurp);
        kec_bind_fe(ctx, "exit", h_exit);
    }
}
