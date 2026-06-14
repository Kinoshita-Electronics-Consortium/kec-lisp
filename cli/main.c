/*
** main.c — the `kec` command-line driver.
**
**   kec                      start the REPL
**   kec repl                 start the REPL
**   kec run FILE [args...]   load + evaluate FILE; args reach (args)
**   kec eval "EXPR"          evaluate EXPR, print the result
**   kec build FILE [-o OUT]  inline (load ...)s, parse-check, write a .kec
**   kec test [FILE...]       run the embedded harness over FILE(s); exit=fails
**   kec version | help
*/
#define _POSIX_C_SOURCE 200809L /* scandir / alphasort / struct dirent */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>

#include "fe.h"
#include "kec.h"
#include "kec_harness_embed.h" /* generated: static const char KEC_HARNESS_SRC[] */

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

static char *read_file(const char *path) {
    FILE *fp = fopen(path, "rb");
    long len;
    char *buf;
    if (!fp) { return NULL; }
    fseek(fp, 0, SEEK_END);
    len = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    buf = malloc((size_t)len + 1);
    if (!buf) { fclose(fp); return NULL; }
    if (fread(buf, 1, (size_t)len, fp) != (size_t)len) { /* tolerate */ }
    buf[len] = '\0';
    fclose(fp);
    return buf;
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
/* build — inline (load ...)s, parse-check, stamp, write.              */
/* ------------------------------------------------------------------ */

/* Pull a quoted path out of a `(load "PATH")` line. Returns 1 on match. */
static int match_load(const char *line, char *out, size_t outsz) {
    const char *p = line;
    const char *q, *end;
    size_t n;
    while (*p == ' ' || *p == '\t') { p++; }
    if (strncmp(p, "(load", 5) != 0) { return 0; }
    q = strchr(p, '"');
    if (!q) { return 0; }
    q++;
    end = strchr(q, '"');
    if (!end) { return 0; }
    n = (size_t)(end - q);
    if (n >= outsz) { n = outsz - 1; }
    memcpy(out, q, n);
    out[n] = '\0';
    return 1;
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

static int bundle(const char *path, Strbuf *out, int depth) {
    char *src = read_file(path);
    char dir[1024];
    char *line, *save;
    if (!src) { fprintf(stderr, "kec build: cannot read %s\n", path); return 1; }
    if (depth > 16) { fprintf(stderr, "kec build: (load ...) nesting too deep\n"); free(src); return 1; }
    dir_of(path, dir, sizeof dir);
    sb_puts(out, ";; --- begin ");
    sb_puts(out, path);
    sb_puts(out, " ---\n");
    for (line = strtok_r(src, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        char rel[1024], full[2048];
        if (match_load(line, rel, sizeof rel)) {
            snprintf(full, sizeof full, "%s%s", dir, rel);
            if (bundle(full, out, depth + 1) != 0) { free(src); return 1; }
        } else {
            sb_puts(out, line);
            sb_puts(out, "\n");
        }
    }
    free(src);
    return 0;
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
    if (bundle(in, &body, 0) != 0) { free(body.p); return 1; }

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
        "  kec run FILE [args...]   evaluate FILE (args reach (args))\n"
        "  kec eval \"EXPR\"          evaluate EXPR and print the result\n"
        "  kec build FILE [-o OUT]  inline loads, parse-check, write a .kec\n"
        "  kec test [FILE...]       run the test harness over FILE(s)\n"
        "  kec version | help\n",
        KEC_VERSION);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { return do_repl(); }
    if (strcmp(argv[1], "repl") == 0) { return do_repl(); }
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
