/*
** host.h — KEC Lisp's portable C primitives.
**
** The primitives that run on any machine with a C library: type reflection,
** math, strings, a little I/O, a few system calls. The KN-86 device primitives
** (text, gfx, psg, spawn-cell, mission, cipher, render) aren't here — the
** firmware registers those through the same `bind` seam (see docs/ffi-bridge.md).
*/
#ifndef KEC_HOST_H
#define KEC_HOST_H

#include <stdint.h>
#include "fe.h"

/*
** A profile is just which primitives a context gets. FULL adds the file and
** system primitives (load, read-file, write-file, append-file, exit, args) on
** top of SANDBOX; SANDBOX leaves them out. Which set a context has is what
** it's allowed to do.
*/
typedef enum {
    KEC_PROFILE_FULL = 0,
    KEC_PROFILE_SANDBOX = 1
} kec_Profile;

/* Max heap buffers simultaneously registered for free-on-error (see
** kec_pending_push). Windows never nest across primitives, so the real
** high-water mark is 1-2; 8 is generous slack. */
#define KEC_PENDING_MAX 8

typedef struct {
    uint64_t rng_state;
    unsigned long gensym_counter; /* per-context: fresh contexts number alike */
    double now_base;              /* (now) epoch: monotonic time at state init */
    void *(*container_alloc)(size_t);
    void (*container_free)(void *);
    void *pending[KEC_PENDING_MAX]; /* malloc'd buffers freed on error unwind */
    int pending_count;
    /* (args)/(argc) source. Context-owned — no cross-context sharing. The
    ** pointers are BORROWED (never copied or freed) and must outlive the
    ** state; main()'s argv qualifies. NULL/0 until the embedder sets them. */
    char **argv;
    int argc;
} kec_HostState;

/* Runtime-owned state for portable host primitives. One instance belongs to
** each interpreter and is attached to Fe userdata slot 1. */
void kec_host_state_init(kec_HostState *state);
void kec_host_attach_state(fe_Context *ctx, kec_HostState *state);
kec_HostState *kec_host_state(fe_Context *ctx);

/* GC-safe symbol→cfunc bind. Saves/restores the GC stack around the two pushes
** (symbol intern + cfunc wrap). Public so embedders can reuse it. */
void kec_bind_fe(fe_Context *ctx, const char *name, fe_CFunc fn);

/* ------------------------------------------------------------------ */
/* Shared argument-conversion helpers. One implementation for the      */
/* whole tree (host, containers, runtime) and for device primitives    */
/* registered through the same seam.                                   */
/* ------------------------------------------------------------------ */

/* Exact printed length of obj in bytes — no allocation. `qt` selects quoted
** (write-style) vs raw (princ-style) rendering, matching fe_write. */
size_t kec_strlen_obj(fe_Context *ctx, fe_Object *obj, int qt);

/* Stringify obj into a freshly malloc'd, NUL-terminated buffer sized to the
** real printed length — no fixed ceiling (the GWP-528 stance). Returns NULL
** only on OOM; callers route that through fe_error. The buffer is the
** caller's to free(). *len_out (if non-NULL) receives the byte length. */
char *kec_strdup_obj(fe_Context *ctx, fe_Object *obj, int qt, size_t *len_out);

/* ------------------------------------------------------------------ */
/* Error-path leak guard. fe_error unwinds with longjmp, so a           */
/* primitive holding a malloc'd buffer across a raising Fe call         */
/* (fe_string / fe_cons / fe_read / ...) would leak it — permanently,   */
/* on a fixed-arena device that catches errors and keeps running.       */
/* Register the buffer while that raising window is open; the runtime's */
/* error handler frees everything still registered before it unwinds.   */
/* Pop (no free) once the window closes and free() normally.            */
/*                                                                      */
/* Only for windows that do NOT evaluate user code (reads and           */
/* allocations): across user code an inner caught (try) would free an   */
/* outer frame's still-live buffer. Resources that user evaluation can  */
/* hold (the load FILE*) use a guard-slot unwind-protect in kec.c       */
/* instead.                                                             */
/* ------------------------------------------------------------------ */

/* Register p for free-on-error. On registry overflow (a static bug — the
** window depth is bounded), frees p and raises. */
void kec_pending_push(fe_Context *ctx, void *p);

/* Unregister p (most-recent-first lookup); the caller then owns it again. */
void kec_pending_pop(fe_Context *ctx, void *p);

/* Free every registered buffer. Called by the runtime error handler on the
** unwind path; idempotent on an empty registry. */
void kec_host_state_free_pending(kec_HostState *state);

/* Pull the next argument as an exact integer. Fractional, non-finite, or
** out-of-signed-32-bit-range numbers raise a catchable
** "<who>: expected an integer". Every integer-taking host API funnels its
** float->int narrowing through this (or the byte variant below) so no cast
** can hit undefined behavior. */
int32_t kec_checked_int(fe_Context *ctx, fe_Object **args, const char *who);

/* As kec_checked_int, but additionally requires 0..255
** ("<who>: expected byte 0..255"). */
int kec_checked_byte(fe_Context *ctx, fe_Object **args, const char *who);

/* Bind the portable host stdlib into ctx for the given profile. */
void kec_host_register(fe_Context *ctx, kec_Profile profile);

/* Bind vector + hash-table primitives and register their typed FE_TPTR
** lifecycle. Called by kec_host_register; safe in any profile. */
void kec_containers_register(fe_Context *ctx);

/* Set the process default used by subsequently initialized host states. Kept
** for source compatibility; prefer kec_set_container_allocator_for(kec_State*)
** so independent contexts can use independent allocation domains. */
void kec_set_container_allocator(void *(*alloc)(size_t), void (*free_)(void *));
void kec_host_state_set_container_allocator(kec_HostState *state,
                                            void *(*alloc)(size_t),
                                            void (*free_)(void *));

/* Expose argv to this state's (args). Per-state, replacing the old
** process-global (the GWP-235/584 context-ownership rule); embedders with a
** kec_State should call the kec_set_args wrapper (kec.h) instead. The
** pointers are borrowed and must outlive the state. */
void kec_host_state_set_args(kec_HostState *state, int argc, char **argv);

#endif /* KEC_HOST_H */
