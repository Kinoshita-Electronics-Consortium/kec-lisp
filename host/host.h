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

/* GC-safe symbol→cfunc bind. Saves/restores the GC stack around the two pushes
** (symbol intern + cfunc wrap). Public so embedders can reuse it. */
void kec_bind_fe(fe_Context *ctx, const char *name, fe_CFunc fn);

/* Bind the portable host stdlib into ctx for the given profile. */
void kec_host_register(fe_Context *ctx, kec_Profile profile);

/* Bind the vector + hash-table container primitives into ctx and install the
** shared FE_TPTR mark/gc handlers. Called by kec_host_register; portable and
** safe in any profile. See host/containers.c and ADR-0003. */
void kec_containers_register(fe_Context *ctx);

/* Override the allocator for container backing memory (vector element arrays,
** hash slot arrays). Defaults to malloc/free; the no-malloc device path installs
** an arena-bump allocator here. Pass NULL for either to reset it to the default.
** Set this before opening contexts that allocate containers. */
void kec_set_container_allocator(void *(*alloc)(size_t), void (*free_)(void *));

/* Expose CLI argv to (args). Call once before evaluation. */
void kec_host_set_args(int argc, char **argv);

#endif /* KEC_HOST_H */
