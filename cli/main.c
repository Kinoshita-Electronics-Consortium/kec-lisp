/*
** main.c — the `kec` command-line driver.
**
**   kec                      start the REPL (editor tier: history + completion)
**   kec repl                 start the REPL
**   kec nemacs [FILE]        open FILE in the knEmacs text editor
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
#include <poll.h>
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
    fe_set_symbol_protection_enabled(kec_fe(S), 0);
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
    kec_protect_standard_globals(S);
    if (loaded > 0) {
        fprintf(stderr, "kec: dev mode — reloaded %d Core file(s) from %s\n", loaded, dir);
    }
}

/* ------------------------------------------------------------------ */
/* Terminal input. One raw byte at a time via read(2), NOT getchar: stdio  */
/* buffering is invisible to poll()/select(), so a buffered byte would make */
/* the idle-timer's poll-timeout (do_nemacs) fire spuriously. Under raw mode */
/* (VMIN=1/VTIME=0) read(2) blocks for exactly one byte, like getchar did.   */
/* ------------------------------------------------------------------ */
static int rd1(void) {
    unsigned char b;
    ssize_t n = read(STDIN_FILENO, &b, 1);
    return (n == 1) ? (int)b : EOF;
}

/* (read-key) -> the next input byte as a number, or nil at end-of-input.
** Blocks until a byte arrives (under raw mode, exactly one keystroke). */
static fe_Object *l_read_key(fe_Context *ctx, fe_Object *args) {
    int c;
    (void)args;
    c = rd1();
    return (c == EOF) ? fe_bool(ctx, 0) : fe_number(ctx, (fe_Number)c);
}

/* (poll-key secs) -> the next input byte as a number if one arrives within
** `secs` seconds, else nil (timeout or end-of-input). secs may be fractional;
** 0 is a pure poll. A non-blocking wait via poll() on stdin — the Lisp-facing
** equivalent of Emacs's (read-event nil nil TIMEOUT). */
static fe_Object *l_poll_key(fe_Context *ctx, fe_Object *args) {
    double secs = (double)fe_tonumber(ctx, fe_nextarg(ctx, &args));
    struct pollfd pfd;
    int ms, r, c;
    if (secs < 0) { secs = 0; }
    ms = (int)(secs * 1000.0);
    pfd.fd = STDIN_FILENO;
    pfd.events = POLLIN;
    r = poll(&pfd, 1, ms);
    if (r <= 0) { return fe_bool(ctx, 0); }   /* timeout or error: no key */
    c = rd1();                                /* ready (data or EOF/HUP) */
    return (c == EOF) ? fe_bool(ctx, 0) : fe_number(ctx, (fe_Number)c);
}

/* Open a FULL-profile context for a runtime subcommand, applying the
** KEC_CORE_DIR dev override if set, and binding the terminal-input seam
** (read-key / poll-key) so both `kec run` scripts and the editor reach it.
** These are CLI host primitives, NOT portable host.c: raw-mode/poll-on-stdin
** is terminal-specific; the device firmware registers the same Lisp names over
** its own input (HID/evdev) — see docs/ffi-bridge.md. (build uses kec_open
** directly — it only parse-checks a bundle and has no reason to reload Core.) */
static kec_State *cli_open(void) {
    kec_State *S = kec_open(ARENA_BYTES, KEC_PROFILE_FULL);
    if (S) {
        maybe_load_dev_core(S);
        kec_bind_fe(kec_fe(S), "read-key", l_read_key);
        kec_bind_fe(kec_fe(S), "poll-key", l_poll_key);
    }
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

/* Append `s` to `b` escaped for embedding inside a Lisp "..." literal. */
static void sb_put_escaped(Strbuf *b, const char *s) {
    for (; *s; s++) {
        char c = *s;
        if (c == '\\' || c == '"') { sb_putn(b, "\\", 1); sb_putn(b, &c, 1); }
        else if (c == '\n') { sb_puts(b, "\\n"); }
        else { sb_putn(b, &c, 1); }
    }
}

/* `kec repl` — load the embedded editor/REPL tier (ADR-0002) and drive its
** REPL engine: read a (paren-balanced) form, hand it to (host-repl-line ...),
** print the engine's formatted output. The history ring + pretty-printer + error
** recovery + live completion all live in the Lisp tier; this is just the terminal
** host (the SEAM's reference implementation). */
static int do_repl(void) {
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
    if (kec_eval_string(S, "(set *repl* (make-session 64 72))", NULL) != 0) {
        fprintf(stderr, "kec: repl session failed: %s\n", kec_error(S));
        kec_close(S);
        return 1;
    }
    /* Prompts + banner go to stderr so stdout carries only results (scriptable);
    ** both are still visible on an interactive terminal. */
    fprintf(stderr, "KEC Lisp %s REPL  —  :q to quit\n", KEC_VERSION);
    acc[0] = '\0';
    for (;;) {
        fprintf(stderr, depth > 0 ? "..   " : "kec> ");
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
            sb_puts(&src, "(host-repl-line *repl* \"");
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
/* nemacs — the interactive structural-editor TTY surface.             */
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

/* Map a zipper boundary ("invalid move: ...") to a calm, Emacs-style echo-area
** message preceded by a BEL — hitting an edge is a non-event in Emacs (it beeps
** and says "End of buffer"), never an error. Real errors keep the "! " prefix. */
static void soft_status(char *status, size_t ssz, const char *err) {
    const char *m;
    if (!strstr(err, "invalid move:")) { snprintf(status, ssz, "! %s", err); return; }
    if      (strstr(err, "end of buffer"))       m = "End of buffer";
    else if (strstr(err, "beginning of buffer")) m = "Beginning of buffer";
    else if (strstr(err, "past last")  || strstr(err, "next-sibling at root")) m = "End of list";
    else if (strstr(err, "past first") || strstr(err, "prev-sibling at root")) m = "Beginning of list";
    else if (strstr(err, "descend into leaf")) m = "No list to enter";
    else if (strstr(err, "ascend"))            m = "At top level";
    else if (strstr(err, "transpose"))         m = "Nothing to transpose";
    else if (strstr(err, "splice"))            m = "Nothing to splice here";
    else if (strstr(err, "insert"))            m = "Cannot insert here";
    else if (strstr(err, "delete"))            m = "Cannot delete the top level";
    else if (strstr(err, "paste"))             m = "Nothing to yank";
    else                                       m = "No move";
    snprintf(status, ssz, "\a%s", m);   /* BEL + calm message, no "!" */
}

/* Eval a Lisp expression for its side effect; on a structural boundary render a
** soft echo (BEL + message), on a real error the "! ..." message. */
static void edit_do(kec_State *S, const char *src, char *status, size_t ssz) {
    if (kec_eval_string(S, src, NULL) != 0) {
        soft_status(status, ssz, kec_error(S));
    }
}

/* C-x C-s — write the buffer back to FILE (save-buffer).
** Routed through the length-aware (write-file ...) FFI primitive: the whole
** buffer is written byte-exact at any size (no fixed C buffer to truncate) and
** VERBATIM. text->string already carries the buffer's trailing newline, so we
** must NOT append one — the old `fputc('\n')` grew the file by a blank line on
** every save. On success the dirty flag is cleared so the modeline drops its "*"
** and the quit guard knows there is nothing left to lose. */
static void save_buffer(kec_State *S, const char *file, char *status, size_t ssz) {
    Strbuf q = {0};
    if (!file) { snprintf(status, ssz, "No file (open with: kec nemacs FILE)"); return; }
    sb_puts(&q, "(write-file \"");
    sb_put_escaped(&q, file);
    sb_puts(&q, "\" (text->string *nemacs*))");
    if (kec_eval_string(S, q.p, NULL) == 0) {
        kec_eval_string(S, "(text-mark-saved! *nemacs*)", NULL);
        snprintf(status, ssz, "Wrote %s", file);
    } else {
        snprintf(status, ssz, "! cannot write %s", file);
    }
    free(q.p);
}

/* Eval `expr`, expecting a string; copy it into `out`. Returns 1 on success. */
static int lisp_str(kec_State *S, const char *expr, char *out, size_t n) {
    fe_Object *v = NULL;
    if (kec_eval_string(S, expr, &v) == 0 && v && fe_type(kec_fe(S), v) == FE_TSTRING) {
        fe_tostring(kec_fe(S), v, out, n);
        return 1;
    }
    return 0;
}

/* Eval `expr`, expecting a number; return it (0 on failure). */
static double lisp_num(kec_State *S, const char *expr) {
    fe_Object *v = NULL;
    if (kec_eval_string(S, expr, &v) == 0 && v && fe_type(kec_fe(S), v) == FE_TNUMBER) {
        return (double)fe_tonumber(kec_fe(S), v);
    }
    return 0;
}

/* Does the buffer have unsaved edits? Drives the quit guard. */
static int buffer_modified(kec_State *S) {
    char m[4];
    return lisp_str(S, "(if (text-modified? *nemacs*) \"1\" \"0\")", m, sizeof m)
           && m[0] == '1';
}

/* Paint one editor frame: clear the screen, ask the Lisp renderer for the
** modeline + text window + echo line (with `status` on the echo line) and print
** it. text-screen emits only the visible window, so the screen buffer is bounded
** by the terminal size, never the buffer size. */
static void render_frame(kec_State *S, int cols, int rows, const char *status) {
    Strbuf call = {0};
    char dims[40];
    fe_Object *v = NULL;
    printf("\x1b[2J\x1b[H");
    sb_puts(&call, "(text-screen *nemacs*");
    snprintf(dims, sizeof dims, " %d %d \"", cols, rows);
    sb_puts(&call, dims);
    sb_put_escaped(&call, status);
    sb_puts(&call, "\")");
    if (kec_eval_string(S, call.p, &v) == 0 && v && fe_type(kec_fe(S), v) == FE_TSTRING) {
        static char scr[1 << 16];
        fe_tostring(kec_fe(S), v, scr, sizeof scr);
        fputs(scr, stdout);
    }
    free(call.p);
    fflush(stdout);
}

/* C-x C-c with unsaved edits: ask before discarding (Emacs never drops work
** silently). Returns 1 to proceed with the exit — saving first when the user
** answers y and a file is open — or 0 to cancel and stay. A clean buffer has
** nothing to ask, so it exits straight away. */
static int confirm_quit(kec_State *S, const char *file, int cols, int rows,
                        char *status, size_t ssz) {
    const char *prompt;
    if (!buffer_modified(S)) { return 1; }
    prompt = file ? "Save modified buffer before quit? (y/n, C-g cancel)"
                  : "Modified buffer has no file; quit and lose changes? (y/n, C-g cancel)";
    for (;;) {
        int c;
        render_frame(S, cols, rows, prompt);
        c = rd1();
        if (c == EOF) { return 1; }                          /* input closed: exit */
        if (c == 'y' || c == 'Y') {
            if (file) { save_buffer(S, file, status, ssz); }
            return 1;
        }
        if (c == 'n' || c == 'N') { return 1; }
        if (c == 7) { snprintf(status, ssz, "\aQuit cancelled"); return 0; }  /* C-g */
        /* any other key: re-ask */
    }
}

/* Ask the Lisp search verb to find `pat` at/after (fr,fc) and move point/mark.
** Returns 1 if a match was found (point moved), 0 otherwise. */
static int search_at(kec_State *S, const char *pat, int fr, int fc) {
    Strbuf q = {0};
    char tail[64], r[4];
    int found;
    sb_puts(&q, "(if (text-search-move! *nemacs* \"");
    sb_put_escaped(&q, pat);
    snprintf(tail, sizeof tail, "\" %d %d) \"1\" \"0\")", fr, fc);
    sb_puts(&q, tail);
    found = (lisp_str(S, q.p, r, sizeof r) && r[0] == '1');
    free(q.p);
    return found;
}

/* C-s incremental search. A small input loop owned by the host: printable keys
** extend the pattern (re-search from the search origin), C-s repeats forward from
** point, DEL shrinks, C-g cancels (restoring point to the origin), RET or any
** other key accepts (point stays at the match). The match move + mark live in the
** Lisp verb text-search-move!; here we track the pattern + origin and repaint. */
static void isearch(kec_State *S, int cols, int rows, char *status, size_t ssz) {
    char pat[256];
    size_t plen = 0;
    int orow, ocol, found = 1;
    pat[0] = '\0';
    orow = (int)lisp_num(S, "(text-point-row *nemacs*)");
    ocol = (int)lisp_num(S, "(text-point-col *nemacs*)");
    for (;;) {
        int c;
        char line[320];
        snprintf(line, sizeof line, "%s%s",
                 (plen == 0 || found) ? "I-search: " : "Failing I-search: ", pat);
        render_frame(S, cols, rows, line);
        c = rd1();
        if (c == EOF) { return; }
        if (c == 7) {                                   /* C-g: cancel, restore point */
            char g[64];
            snprintf(g, sizeof g, "(text-goto! *nemacs* %d %d)", orow, ocol);
            kec_eval_string(S, g, NULL);
            snprintf(status, ssz, "\aQuit");
            return;
        }
        if (c == 13 || c == 10) {                       /* RET: accept (point stays) */
            status[0] = '\0';
            return;
        }
        if (c == 19) {                                  /* C-s: repeat forward from point */
            if (plen) {
                int pr = (int)lisp_num(S, "(text-point-row *nemacs*)");
                int pc = (int)lisp_num(S, "(text-point-col *nemacs*)");
                found = search_at(S, pat, pr, pc);
            }
            continue;
        }
        if (c == 127 || c == 8) {                       /* DEL: shrink pattern */
            if (plen) { pat[--plen] = '\0'; }
            found = (plen == 0) ? 1 : search_at(S, pat, orow, ocol);
            continue;
        }
        if (c >= 32 && c < 127) {                       /* printable: extend pattern */
            if (plen + 1 < sizeof pat) { pat[plen++] = (char)c; pat[plen] = '\0'; }
            found = search_at(S, pat, orow, ocol);
            continue;
        }
        status[0] = '\0';                               /* any other key: accept, exit */
        return;
    }
}

/* Normalize one terminal keystroke into canonical Emacs key notation
** ("C-n", "C-M-f", "M-(", "<up>", "a", "RET", ...). Reads the extra bytes an
** ESC-prefixed Meta key or arrow needs. This is ALL the key knowledge the host
** has — what each key *does* lives in the Lisp binding table (editor/55-bindings). */
static void norm_key(int c, char *out, size_t n) {
    if (c == 27) {                         /* ESC: arrow keys or a Meta prefix */
        int c2 = rd1();
        if (c2 == '[') {
            int c3 = rd1();
            const char *a = (c3 == 'A') ? "<up>"  : (c3 == 'B') ? "<down>"
                          : (c3 == 'C') ? "<right>" : (c3 == 'D') ? "<left>" : "";
            snprintf(out, n, "%s", a);
        } else if (c2 >= 1 && c2 <= 26) {  /* ESC + C-x  ->  C-M-x */
            snprintf(out, n, "C-M-%c", c2 + 96);
        } else if (c2 >= 32 && c2 < 127) { /* ESC + g    ->  M-g */
            snprintf(out, n, "M-%c", c2);
        } else {
            snprintf(out, n, "ESC");
        }
    } else if (c == 31) {                   /* C-/ (a.k.a. C-_) */
        snprintf(out, n, "C-/");
    } else if (c == 0)  { snprintf(out, n, "C-@"); }  /* C-SPC (set-mark) */
    else if (c == 9)  { snprintf(out, n, "TAB"); }
    else if (c == 13 || c == 10) { snprintf(out, n, "RET"); }
    else if (c == 127) { snprintf(out, n, "DEL"); }   /* Backspace */
    else if (c >= 1 && c <= 26) {           /* C-<letter> */
        snprintf(out, n, "C-%c", c + 96);
    } else if (c >= 32 && c < 127) {        /* graphic: the key is itself */
        snprintf(out, n, "%c", c);
    } else {
        snprintf(out, n, "");
    }
}

/* `kec nemacs [FILE]` — open FILE (or an empty *scratch* buffer) in knEmacs, the
** text editor. The buffer is real text (lines + point; editor/32-text); the host
** is just the terminal — it renders the buffer each frame, self-inserts graphic
** keys, and dispatches the rest through the Lisp binding table (editor/55-bindings).
** Motion + editing live in the Lisp tier; the C side owns only terminal + file I/O. */
static int do_nemacs(const char *file) {
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
    /* Build *nemacs*: load FILE if readable, else an empty *scratch* buffer. */
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
        sb_puts(&src, "(set *nemacs* (text-open \"");
        sb_put_escaped(&src, file ? file : "*scratch*");
        sb_puts(&src, "\" \"");
        sb_put_escaped(&src, init.len ? init.p : "");   /* *scratch*: empty buffer */
        sb_puts(&src, "\"))");
        if (kec_eval_string(S, src.p, NULL) != 0) {
            fprintf(stderr, "kec nemacs: %s\n", kec_error(S));
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
        /* Render the frame: clear, then paint the text buffer. The renderer lays
        ** out modeline + text window + the status/echo line and parks the cursor
        ** at point, so the host just prints what it returns. */
        render_frame(S, cols, rows, status);

        c = rd1();
        if (c == EOF) { break; }
        status[0] = '\0';

        /* C-s enters incremental search, which runs its own input loop. (The
        ** save chord C-x C-s is unaffected: C-x is read first and consumes the
        ** following C-s as part of its two-key sequence below.) */
        if (c == 19) { isearch(S, cols, rows, status, sizeof status); continue; }

        /* ----- Emacs command dispatch (keymap-as-data; field-notes A.1) --------
        ** The host normalizes the keystroke to canonical notation, then asks the
        ** Lisp binding table (editor/55-bindings) what it means. The host knows no bindings
        ** of its own — only how to perform the three I/O commands and self-insert.
        ** C-x and C-h are prefix keys assembled here into full sequences. */
        {
            char key[48], tag[96];
            Strbuf q = {0};

            if (c == 24) {                     /* C-x ...  -> "C-x <key>" */
                char k2[24];
                norm_key(rd1(), k2, sizeof k2);
                snprintf(key, sizeof key, "C-x %s", k2);
            } else if (c == 8) {               /* C-h help: describe the next key */
                int h = rd1();
                char k2[24];
                Strbuf d = {0};
                if (h == 'k') { norm_key(rd1(), k2, sizeof k2); }
                else          { norm_key(h, k2, sizeof k2); }   /* lenient: C-h <key> */
                sb_puts(&d, "(describe-key \"");
                sb_put_escaped(&d, k2);
                sb_puts(&d, "\")");
                lisp_str(S, d.p, status, sizeof status);
                free(d.p);
                continue;
            } else {
                norm_key(c, key, sizeof key);
            }

            /* ask the keymap what this key resolves to */
            sb_puts(&q, "(resolve-key \"");
            sb_put_escaped(&q, key);
            sb_puts(&q, "\")");
            if (!lisp_str(S, q.p, tag, sizeof tag)) { tag[0] = '\0'; }
            free(q.p);

            if (strcmp(tag, "self-insert") == 0) {        /* insert the graphic key */
                Strbuf src = {0};
                char one[2];
                one[0] = key[0]; one[1] = '\0';
                sb_puts(&src, "(text-insert! *nemacs* \"");
                sb_put_escaped(&src, one);
                sb_puts(&src, "\")");
                edit_do(S, src.p, status, sizeof status);
                free(src.p);
            } else if (strncmp(tag, "buffer:", 7) == 0) { /* a text-buffer verb */
                char src[96];
                snprintf(src, sizeof src, "(%s *nemacs*)", tag + 7);
                edit_do(S, src, status, sizeof status);
            } else if (strcmp(tag, "host:save-buffer") == 0) {
                save_buffer(S, file, status, sizeof status);
            } else if (strcmp(tag, "host:exit-editor") == 0) {
                if (confirm_quit(S, file, cols, rows, status, sizeof status)) { break; }
            } else if (strcmp(tag, "host:keyboard-quit") == 0) {
                snprintf(status, sizeof status, "\aQuit");
            } else if (key[0]) {                          /* "undefined" */
                snprintf(status, sizeof status, "\a%s is undefined  (C-h k describes a key)", key);
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
        "  kec repl                 start the REPL (history, completion, pretty-print)\n"
        "  kec nemacs [FILE]        open FILE in the knEmacs text editor\n"
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
    if (strcmp(argv[1], "nemacs") == 0) { return do_nemacs(argc > 2 ? argv[2] : NULL); }
    if (strcmp(argv[1], "edit") == 0) { return do_nemacs(argc > 2 ? argv[2] : NULL); }
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
