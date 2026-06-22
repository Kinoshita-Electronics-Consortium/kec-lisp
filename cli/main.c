/*
** main.c — the `kec` command-line driver.
**
**   kec                      start the REPL
**   kec repl                 start the REPL
**   kec run FILE [args...]   load + evaluate FILE; args reach (args)
**   kec eval "EXPR"          evaluate EXPR, print the result
**   kec build FILE [-o OUT]  inline top-level loads, parse-check, write a .kec
**   kec test [FILE...]       run the harness over FILE(s), or the whole
**                            embedded suite when no FILE is given; exit=fails
**   kec version | help
*/
#define _POSIX_C_SOURCE 200809L /* scandir / alphasort / struct dirent */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <setjmp.h>
#include <termios.h>
#include <unistd.h>
#include <sys/ioctl.h>

#include "fe.h"
#include "kec.h"
#include "kec_harness_embed.h" /* generated: static const char KEC_HARNESS_SRC[] */
#include "kec_suite_embed.h"   /* generated: static const char KEC_SUITE_SRC[]   */
#include "kec_editor_embed.h"  /* generated: static const char KEC_EDITOR_SRC[]  */

#ifndef KEC_VERSION
#define KEC_VERSION "0.1.0"
#endif

#define ARENA_BYTES (16u * 1024u * 1024u)

/* ------------------------------------------------------------------ */
/* Small growable string buffer (for `build`).                         */
/* ------------------------------------------------------------------ */

typedef struct { char *p; size_t len, cap; } Strbuf;

static void sb_putn(Strbuf *b, const char *s, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 1024;
        while (cap < b->len + n + 1) { cap *= 2; }
        b->p = realloc(b->p, cap);
        b->cap = cap;
    }
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = '\0';
}
static void sb_puts(Strbuf *b, const char *s) { sb_putn(b, s, strlen(s)); }

static void sb_writefe(fe_Context *ctx, void *udata, char chr) {
    (void)ctx;
    sb_putn((Strbuf *)udata, &chr, 1);
}

/* ------------------------------------------------------------------ */
/* Dev convenience: reload Core from disk (KEC_CORE_DIR).              */
/* ------------------------------------------------------------------ */

/* When KEC_CORE_DIR is set, re-load the directory's .lsp files on top of
** the embedded Core, so an edit to a Core module takes effect without rebuilding
** the binary — the prototyping fast path. Files load in name order; the NN-
** numeric prefixes encode dependency order, which alphasort preserves.
**
** Dev-only, and it *layers over* the embedded prelude: a definition you delete
** from a file still lingers from the baked-in copy until you rebuild. Adding and
** changing definitions (the common case while prototyping) works live. */
static void maybe_load_dev_core(kec_State *S) {
    const char *dir = getenv("KEC_CORE_DIR");
    struct dirent **names = NULL;
    int n, i, loaded = 0;
    if (!dir || !*dir) { return; }
    n = scandir(dir, &names, NULL, alphasort);
    if (n < 0) {
        fprintf(stderr, "kec: KEC_CORE_DIR=%s cannot be read; using embedded Core\n", dir);
        return;
    }
    for (i = 0; i < n; i++) {
        const char *nm = names[i]->d_name;
        size_t len = strlen(nm);
        if (len > 4 && strcmp(nm + len - 4, ".lsp") == 0) {
            char path[2048];
            snprintf(path, sizeof path, "%s/%s", dir, nm);
            if (kec_eval_file(S, path, NULL) != 0) {
                fprintf(stderr, "kec: dev Core %s: %s\n", path, kec_error(S));
            } else {
                loaded++;
            }
        }
        free(names[i]);
    }
    free(names);
    if (loaded > 0) {
        fprintf(stderr, "kec: dev mode — reloaded %d Core file(s) from %s\n", loaded, dir);
    }
}

/* Open a FULL-profile context for a runtime subcommand, applying the
** KEC_CORE_DIR dev override if set. (build uses kec_open directly — it only
** parse-checks a bundle and has no reason to reload Core.) */
static kec_State *cli_open(void) {
    kec_State *S = kec_open(ARENA_BYTES, KEC_PROFILE_FULL);
    if (S) { maybe_load_dev_core(S); }
    return S;
}

/* ------------------------------------------------------------------ */
/* REPL.                                                               */
/* ------------------------------------------------------------------ */

/* Count net paren depth on a line, skipping ; comments and "..." strings. */
static int paren_delta(const char *s) {
    int depth = 0, instr = 0;
    for (; *s; s++) {
        if (instr) {
            if (*s == '\\' && s[1]) { s++; }
            else if (*s == '"') { instr = 0; }
            continue;
        }
        if (*s == ';') { break; }
        if (*s == '"') { instr = 1; }
        else if (*s == '(') { depth++; }
        else if (*s == ')') { depth--; }
    }
    return depth;
}

static int do_repl(void) {
    kec_State *S = cli_open();
    char line[4096], acc[16384];
    int depth = 0;
    size_t acclen = 0;
    if (!S) { fprintf(stderr, "kec: failed to open interpreter\n"); return 1; }
    printf("KEC Lisp %s  (KN-86 Standard)  —  :q to quit\n", KEC_VERSION);
    acc[0] = '\0';
    for (;;) {
        printf(depth > 0 ? "..  " : "kec> ");
        fflush(stdout);
        if (!fgets(line, sizeof line, stdin)) { printf("\n"); break; }
        if (depth == 0 && (strcmp(line, ":q\n") == 0 || strcmp(line, ":quit\n") == 0)) { break; }
        if (acclen + strlen(line) < sizeof acc) {
            strcpy(acc + acclen, line);
            acclen += strlen(line);
        }
        depth += paren_delta(line);
        if (depth > 0) { continue; } /* form still open — keep reading */
        depth = 0;
        {
            fe_Object *v = NULL;
            if (kec_eval_string(S, acc, &v) != 0) {
                fprintf(stderr, "error: %s\n", kec_error(S));
            } else if (v) {
                printf("=> ");
                fe_writefp(kec_fe(S), v, stdout);
                printf("\n");
            }
        }
        acc[0] = '\0';
        acclen = 0;
    }
    kec_close(S);
    return 0;
}

/* ------------------------------------------------------------------ */
/* nemacs — the strong REPL over the embedded editor/REPL tier.        */
/* ------------------------------------------------------------------ */

/* Append `s` to `b` escaped for embedding inside a Lisp "..." literal. */
static void sb_put_escaped(Strbuf *b, const char *s) {
    for (; *s; s++) {
        char c = *s;
        if (c == '\\' || c == '"') { sb_putn(b, "\\", 1); sb_putn(b, &c, 1); }
        else if (c == '\n') { sb_puts(b, "\\n"); }
        else { sb_putn(b, &c, 1); }
    }
}

/* `kec nemacs` — load the embedded editor/REPL tier (ADR-0002) and drive its
** REPL engine: read a (paren-balanced) form, hand it to (host-repl-line ...),
** print the engine's formatted output. The structural editor + history ring +
** pretty-printer + error recovery all live in the Lisp tier; this is just the
** terminal host (the SEAM's reference implementation). */
static int do_nemacs(void) {
    kec_State *S = cli_open();
    char line[4096], acc[16384];
    int depth = 0;
    size_t acclen = 0;
    if (!S) { fprintf(stderr, "kec: failed to open interpreter\n"); return 1; }
    if (kec_eval_string(S, KEC_EDITOR_SRC, NULL) != 0) {
        fprintf(stderr, "kec: editor tier failed to load: %s\n", kec_error(S));
        kec_close(S);
        return 1;
    }
    if (kec_eval_string(S, "(set *nemacs* (make-session 64 72))", NULL) != 0) {
        fprintf(stderr, "kec: nemacs session failed: %s\n", kec_error(S));
        kec_close(S);
        return 1;
    }
    /* Prompts + banner go to stderr so stdout carries only results (scriptable);
    ** both are still visible on an interactive terminal. */
    fprintf(stderr, "nEmacs (KEC Lisp %s)  —  structural REPL  —  :q to quit\n", KEC_VERSION);
    acc[0] = '\0';
    for (;;) {
        fprintf(stderr, depth > 0 ? "..      " : "nemacs> ");
        fflush(stderr);
        if (!fgets(line, sizeof line, stdin)) { printf("\n"); break; }
        if (depth == 0 && (strcmp(line, ":q\n") == 0 || strcmp(line, ":quit\n") == 0)) { break; }
        if (acclen + strlen(line) < sizeof acc) {
            strcpy(acc + acclen, line);
            acclen += strlen(line);
        }
        depth += paren_delta(line);
        if (depth > 0) { continue; } /* form still open — keep reading */
        depth = 0;
        {
            Strbuf src = {0};
            fe_Object *v = NULL;
            sb_puts(&src, "(host-repl-line *nemacs* \"");
            sb_put_escaped(&src, acc);
            sb_puts(&src, "\")");
            if (kec_eval_string(S, src.p, &v) != 0) {
                fprintf(stderr, "error: %s\n", kec_error(S));
            } else if (v && fe_type(kec_fe(S), v) == FE_TSTRING) {
                char out[16384];
                fe_tostring(kec_fe(S), v, out, sizeof out);
                printf("%s\n", out);
            }
            free(src.p);
        }
        acc[0] = '\0';
        acclen = 0;
    }
    kec_close(S);
    return 0;
}

/* ------------------------------------------------------------------ */
/* edit — the interactive structural-editor TTY surface.               */
/* ------------------------------------------------------------------ */

static struct termios g_orig_tio;
static int g_raw = 0;

static void edit_raw_on(void) {
    struct termios raw;
    if (tcgetattr(STDIN_FILENO, &g_orig_tio) != 0) { return; } /* not a tty (piped) */
    raw = g_orig_tio;
    raw.c_lflag &= ~(unsigned)(ICANON | ECHO);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0) { g_raw = 1; }
}
static void edit_raw_off(void) {
    if (g_raw) { tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_orig_tio); }
    g_raw = 0;
}

/* A keystroke -> a structural command token (and its event type), or NULL for
** a non-structural key (handled directly as a session command). The structural
** keys drive the engine through the keymap — the same :nemacs-nav grammar the
** device uses. */
static const char *edit_token(int c, const char **etype) {
    *etype = "':tap";
    switch (c) {
        case 'l': return "'CAR";    /* descend into first child */
        case 'h': return "'BACK";   /* ascend to parent */
        case 'j': return "'CDR";    /* next sibling */
        case 'k': return "'QUOTE";  /* prev sibling */
        case 'w': return "'CONS";   /* wrap focus in a list */
        case 's': return "'LINK";   /* splice a list into its parent */
        case 'd': *etype = "':long-press"; return "'CDR"; /* delete (cut) */
        default: return NULL;
    }
}

/* Eval a Lisp expression for its side effect; on error stash the message in
** `status`. */
static void edit_do(kec_State *S, const char *src, char *status, size_t ssz) {
    if (kec_eval_string(S, src, NULL) != 0) {
        snprintf(status, ssz, "! %s", kec_error(S));
    }
}

/* `kec edit [FILE]` — open FILE (or a scratch buffer) in the structural editor.
** Renders the view model each frame and dispatches keys through the :nemacs-nav
** keymap; structural edits, eval, insert, undo, and save are all driven from the
** Lisp tier (the C side is the terminal host). */
static int do_edit(const char *file) {
    kec_State *S = cli_open();
    char status[256];
    struct winsize ws;
    int cols = 80, rows = 24;
    status[0] = '\0';
    if (!S) { fprintf(stderr, "kec: failed to open interpreter\n"); return 1; }
    if (kec_eval_string(S, KEC_EDITOR_SRC, NULL) != 0) {
        fprintf(stderr, "kec: editor tier failed to load: %s\n", kec_error(S));
        kec_close(S);
        return 1;
    }
    /* Build *edit*: load FILE if readable, else a scratch buffer of "()". */
    {
        Strbuf init = {0}, src = {0};
        if (file) {
            FILE *fp = fopen(file, "rb");
            if (fp) {
                int ch;
                while ((ch = fgetc(fp)) != EOF) { char cc = (char)ch; sb_putn(&init, &cc, 1); }
                fclose(fp);
            }
        }
        sb_puts(&src, "(set *edit* (buffer-load \"");
        sb_put_escaped(&src, file ? file : "*scratch*");
        sb_puts(&src, "\" \"");
        sb_put_escaped(&src, init.len ? init.p : "()");
        sb_puts(&src, "\"))");
        if (kec_eval_string(S, src.p, NULL) != 0) {
            fprintf(stderr, "kec edit: %s\n", kec_error(S));
            free(src.p); free(init.p); kec_close(S);
            return 1;
        }
        free(src.p); free(init.p);
    }
    edit_raw_on();
    for (;;) {
        int c;
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
            cols = ws.ws_col; rows = ws.ws_row;
        }
        /* Render the frame: clear, paint the view model, then the status line. */
        printf("\x1b[2J\x1b[H");
        {
            char call[64];
            fe_Object *v = NULL;
            snprintf(call, sizeof call, "(tty-screen *edit* %d %d)", cols, rows);
            if (kec_eval_string(S, call, &v) == 0 && v && fe_type(kec_fe(S), v) == FE_TSTRING) {
                static char scr[1 << 16];
                fe_tostring(kec_fe(S), v, scr, sizeof scr);
                fputs(scr, stdout);
            }
        }
        printf("\n%s", status);
        fflush(stdout);

        c = getchar();
        if (c == EOF || c == 'q') { break; }
        status[0] = '\0';
        {
            const char *etype;
            const char *tok = edit_token(c, &etype);
            if (tok) {
                char src[160];
                snprintf(src, sizeof src,
                         "(mode-dispatch ':nemacs-nav %s %s *edit*)", tok, etype);
                edit_do(S, src, status, sizeof status);   /* boundary -> status */
            } else if (c == 't') {
                edit_do(S, "(buffer-transpose! *edit*)", status, sizeof status);
            } else if (c == 'u') {
                edit_do(S, "(buffer-undo! *edit*)", status, sizeof status);
            } else if (c == 'e') {
                fe_Object *v = NULL;
                if (kec_eval_string(S,
                        "(try (fn () (repr (eval (buffer-focus *edit*)))))", &v) == 0
                    && v && fe_type(kec_fe(S), v) == FE_TSTRING) {
                    char r[1024];
                    fe_tostring(kec_fe(S), v, r, sizeof r);
                    snprintf(status, sizeof status, "=> %s", r);
                }
            } else if (c == 'i') {
                char line[1024];
                edit_raw_off();
                printf("\ninsert: ");
                fflush(stdout);
                if (fgets(line, sizeof line, stdin)) {
                    Strbuf src = {0};
                    size_t n = strlen(line);
                    if (n && line[n - 1] == '\n') { line[n - 1] = '\0'; }
                    sb_puts(&src, "(buffer-insert-leaf! *edit* (read-string \"");
                    sb_put_escaped(&src, line);
                    sb_puts(&src, "\"))");
                    edit_do(S, src.p, status, sizeof status);
                    free(src.p);
                }
                edit_raw_on();
            } else if (c == 'W') {
                fe_Object *v = NULL;
                if (!file) {
                    snprintf(status, sizeof status, "! no file to save");
                } else if (kec_eval_string(S, "(buffer->string *edit*)", &v) == 0
                           && v && fe_type(kec_fe(S), v) == FE_TSTRING) {
                    static char buf[1 << 16];
                    FILE *fp;
                    fe_tostring(kec_fe(S), v, buf, sizeof buf);
                    fp = fopen(file, "wb");
                    if (fp) {
                        fputs(buf, fp); fputc('\n', fp); fclose(fp);
                        snprintf(status, sizeof status, "saved %s", file);
                    } else {
                        snprintf(status, sizeof status, "! cannot write %s", file);
                    }
                }
            }
        }
    }
    edit_raw_off();
    printf("\x1b[2J\x1b[H");
    fflush(stdout);
    kec_close(S);
    return 0;
}

/* ------------------------------------------------------------------ */
/* run / eval.                                                         */
/* ------------------------------------------------------------------ */

static int do_run(int argc, char **argv) {
    /* argv[0] = FILE, argv[1..] = script args */
    kec_State *S;
    int rc;
    if (argc < 1) { fprintf(stderr, "kec run: missing FILE\n"); return 2; }
    kec_host_set_args(argc, argv); /* (args) -> (FILE script-arg...) */
    S = cli_open();
    if (!S) { fprintf(stderr, "kec: failed to open interpreter\n"); return 1; }
    rc = kec_eval_file(S, argv[0], NULL);
    if (rc != 0) { fprintf(stderr, "kec: %s\n", kec_error(S)); }
    kec_close(S);
    return rc;
}

static int do_eval(const char *src) {
    kec_State *S = cli_open();
    fe_Object *v = NULL;
    int rc;
    if (!S) { fprintf(stderr, "kec: failed to open interpreter\n"); return 1; }
    rc = kec_eval_string(S, src, &v);
    if (rc != 0) {
        fprintf(stderr, "kec: %s\n", kec_error(S));
    } else if (v) {
        fe_writefp(kec_fe(S), v, stdout);
        printf("\n");
    }
    kec_close(S);
    return rc;
}

/* ------------------------------------------------------------------ */
/* test.                                                               */
/* ------------------------------------------------------------------ */

static int do_test(int argc, char **argv) {
    kec_State *S = cli_open();
    int i, failed;
    if (!S) { fprintf(stderr, "kec: failed to open interpreter\n"); return 1; }
    if (kec_eval_string(S, KEC_HARNESS_SRC, NULL) != 0) {
        fprintf(stderr, "kec: harness load failed: %s\n", kec_error(S));
        kec_close(S);
        return 1;
    }
    if (argc == 0) {
        /* No files named: run the whole conformance suite baked into the
        ** binary, so `kec test` works from any directory with no repo on
        ** disk — same self-contained spirit as the embedded Core. */
        printf("• full suite (embedded)\n");
        if (kec_eval_string(S, KEC_SUITE_SRC, NULL) != 0) {
            fprintf(stderr, "  ERROR running embedded suite: %s\n", kec_error(S));
        }
    }
    for (i = 0; i < argc; i++) {
        printf("• %s\n", argv[i]);
        if (kec_eval_file(S, argv[i], NULL) != 0) {
            fprintf(stderr, "  ERROR loading %s: %s\n", argv[i], kec_error(S));
        }
    }
    kec_eval_string(S, "(test-report)", NULL);
    failed = kec_global_int(S, "%tests-failed", 1);
    kec_close(S);
    return failed == 0 ? 0 : 1;
}

/* ------------------------------------------------------------------ */
/* build — inline top-level (load ...) forms, parse-check, stamp, write. */
/* ------------------------------------------------------------------ */

typedef struct {
    jmp_buf recover;
    char errmsg[256];
} BuildReadGuard;

static BuildReadGuard *g_build_read_guard = NULL;

static void build_read_error(fe_Context *ctx, const char *err, fe_Object *cl) {
    (void)ctx;
    (void)cl;
    if (g_build_read_guard) {
        snprintf(g_build_read_guard->errmsg, sizeof g_build_read_guard->errmsg, "%s", err);
        longjmp(g_build_read_guard->recover, 1);
    }
}

/* Directory portion of a path, into `dir` (with trailing slash or empty). */
static void dir_of(const char *path, char *dir, size_t sz) {
    const char *slash = strrchr(path, '/');
    if (!slash) { dir[0] = '\0'; return; }
    {
        size_t n = (size_t)(slash - path) + 1;
        if (n >= sz) { n = sz - 1; }
        memcpy(dir, path, n);
        dir[n] = '\0';
    }
}

static void path_join(const char *dir, const char *rel, char *out, size_t sz) {
    if (rel[0] == '/') { snprintf(out, sz, "%s", rel); }
    else { snprintf(out, sz, "%s%s", dir, rel); }
}

static int load_form_path(fe_Context *ctx, fe_Object *form, char *out, size_t outsz) {
    fe_Object *op, *args, *path, *tail;
    char name[64];
    if (fe_type(ctx, form) != FE_TPAIR) { return 0; }
    op = fe_car(ctx, form);
    if (fe_type(ctx, op) != FE_TSYMBOL) { return 0; }
    fe_tostring(ctx, op, name, sizeof name);
    if (strcmp(name, "load") != 0) { return 0; }
    args = fe_cdr(ctx, form);
    if (fe_type(ctx, args) != FE_TPAIR) { return 0; }
    path = fe_car(ctx, args);
    tail = fe_cdr(ctx, args);
    if (!fe_isnil(ctx, tail) || fe_type(ctx, path) != FE_TSTRING) { return 0; }
    fe_tostring(ctx, path, out, (int)outsz);
    return 1;
}

static int bundle_forms(fe_Context *ctx, const char *path, Strbuf *out, int depth) {
    FILE *fp;
    char dir[1024];
    if (depth > 16) { fprintf(stderr, "kec build: (load ...) nesting too deep\n"); return 1; }
    fp = fopen(path, "rb");
    if (!fp) { fprintf(stderr, "kec build: cannot read %s\n", path); return 1; }
    dir_of(path, dir, sizeof dir);
    sb_puts(out, ";; --- begin ");
    sb_puts(out, path);
    sb_puts(out, " ---\n");
    for (;;) {
        char rel[1024], full[2048];
        int gc = fe_savegc(ctx);
        fe_Object *form = fe_readfp(ctx, fp);
        if (form == NULL) {
            fe_restoregc(ctx, gc);
            break;
        }
        if (load_form_path(ctx, form, rel, sizeof rel)) {
            path_join(dir, rel, full, sizeof full);
            if (bundle_forms(ctx, full, out, depth + 1) != 0) {
                fclose(fp);
                return 1;
            }
        } else {
            fe_write(ctx, form, sb_writefe, out, 1);
            sb_puts(out, "\n");
        }
        fe_restoregc(ctx, gc);
    }
    fclose(fp);
    return 0;
}

static int bundle(const char *path, Strbuf *out) {
    void *arena = malloc(ARENA_BYTES);
    fe_Context *ctx;
    BuildReadGuard guard;
    int rc;
    if (!arena) { fprintf(stderr, "kec build: out of memory\n"); return 1; }
    ctx = fe_open(arena, (int)ARENA_BYTES);
    guard.errmsg[0] = '\0';
    g_build_read_guard = &guard;
    fe_handlers(ctx)->error = build_read_error;
    if (setjmp(guard.recover)) {
        fprintf(stderr, "kec build: parse error while bundling: %s\n", guard.errmsg);
        g_build_read_guard = NULL;
        fe_close(ctx);
        free(arena);
        return 1;
    }
    rc = bundle_forms(ctx, path, out, 0);
    g_build_read_guard = NULL;
    fe_close(ctx);
    free(arena);
    return rc;
}

static int do_build(int argc, char **argv) {
    const char *in = NULL, *outpath = NULL;
    char defout[1024];
    Strbuf body = {0};
    Strbuf full = {0};
    kec_State *S;
    FILE *fp;
    int i, rc = 0;
    for (i = 0; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) { outpath = argv[++i]; }
        else if (!in) { in = argv[i]; }
    }
    if (!in) { fprintf(stderr, "kec build: missing FILE\n"); return 2; }
    if (!outpath) {
        const char *dot = strrchr(in, '.');
        size_t base = dot ? (size_t)(dot - in) : strlen(in);
        snprintf(defout, sizeof defout, "%.*s.kec", (int)base, in);
        outpath = defout;
    }
    if (bundle(in, &body) != 0) { free(body.p); return 1; }

    /* Parse-check the bundled program. */
    S = kec_open(ARENA_BYTES, KEC_PROFILE_FULL);
    if (!S) { fprintf(stderr, "kec: failed to open interpreter\n"); free(body.p); return 1; }
    if (kec_check_string(S, body.p) != 0) {
        fprintf(stderr, "kec build: parse error: %s\n", kec_error(S));
        kec_close(S);
        free(body.p);
        return 1;
    }
    kec_close(S);

    /* Stamp + write. The .kec is self-contained KEC Lisp text (the leading
    ** comment header is skipped by the reader); `kec run out.kec` executes it. */
    sb_puts(&full, ";; KEC Lisp bundle — KN-86 Standard\n");
    sb_puts(&full, ";; kec-version: " KEC_VERSION "\n");
    sb_puts(&full, ";; source: ");
    sb_puts(&full, in);
    sb_puts(&full, "\n");
    sb_putn(&full, body.p, body.len);

    fp = fopen(outpath, "wb");
    if (!fp) { fprintf(stderr, "kec build: cannot write %s\n", outpath); rc = 1; }
    else {
        fwrite(full.p, 1, full.len, fp);
        fclose(fp);
        printf("kec build: wrote %s (%zu bytes)\n", outpath, full.len);
    }
    free(body.p);
    free(full.p);
    return rc;
}

/* ------------------------------------------------------------------ */
/* Entry.                                                              */
/* ------------------------------------------------------------------ */

static int usage(FILE *fp) {
    fprintf(fp,
        "KEC Lisp %s — the KN-86 Standard authoring language\n\n"
        "usage:\n"
        "  kec                      start the REPL\n"
        "  kec nemacs               start the knEmacs structural REPL (editor tier)\n"
        "  kec edit [FILE]          open FILE in the structural editor (editor tier)\n"
        "  kec run FILE [args...]   evaluate FILE (args reach (args))\n"
        "  kec eval \"EXPR\"          evaluate EXPR and print the result\n"
        "  kec build FILE [-o OUT]  inline top-level loads, parse-check, write a .kec\n"
        "  kec test [FILE...]       run the suite (default: whole embedded suite)\n"
        "  kec version | help\n",
        KEC_VERSION);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { return do_repl(); }
    if (strcmp(argv[1], "repl") == 0) { return do_repl(); }
    if (strcmp(argv[1], "nemacs") == 0) { return do_nemacs(); }
    if (strcmp(argv[1], "edit") == 0) { return do_edit(argc > 2 ? argv[2] : NULL); }
    if (strcmp(argv[1], "run") == 0) { return do_run(argc - 2, argv + 2); }
    if (strcmp(argv[1], "eval") == 0) {
        if (argc < 3) { fprintf(stderr, "kec eval: missing EXPR\n"); return 2; }
        return do_eval(argv[2]);
    }
    if (strcmp(argv[1], "build") == 0) { return do_build(argc - 2, argv + 2); }
    if (strcmp(argv[1], "test") == 0) { return do_test(argc - 2, argv + 2); }
    if (strcmp(argv[1], "version") == 0) { printf("KEC Lisp %s\n", KEC_VERSION); return 0; }
    if (strcmp(argv[1], "help") == 0 || strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        return usage(stdout);
    }
    /* Bare `kec FILE.lsp` convenience → run it. */
    if (argv[1][0] != '-') { return do_run(argc - 1, argv + 1); }
    usage(stderr);
    return 2;
}
