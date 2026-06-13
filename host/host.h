/*
** host.h — KEC Lisp portable host stdlib (Layer 2, standalone profile).
**
** This is the part of KEC Stdlib that runs on any host with a C library:
** type reflection, math, strings, minimal I/O, and a few system hooks. It
** deliberately excludes the KN-86 device FFI (text, gfx, psg, spawn-cell,
** mission, cipher, render primitives) — that surface is registered
** downstream by the firmware through the same `bind` seam (see
** docs/ffi-bridge.md and kec-lisp-language-standard.md section 6).
*/
#ifndef KEC_HOST_H
#define KEC_HOST_H

#include "fe.h"

/*
** Capability profile = which host primitives a context is created with.
** This is the standalone repo's worked example of "capability is the
** binding-set" (standard §2.1, §6.4): the FULL profile adds file I/O,
** `load`, `read`, `exit`, and `args` on top of the SANDBOX surface.
*/
typedef enum {
    KEC_PROFILE_FULL = 0,
    KEC_PROFILE_SANDBOX = 1
} kec_Profile;

/* GC-safe symbol→cfunc bind (the §6.1 seam). Saves/restores the GC stack
** around the two pushes (symbol intern + cfunc wrap). Public so downstream
** FFI can reuse it verbatim. */
void kec_bind_fe(fe_Context *ctx, const char *name, fe_CFunc fn);

/* Bind the portable host stdlib into ctx for the given profile. */
void kec_host_register(fe_Context *ctx, kec_Profile profile);

/* Expose CLI argv to (args). Call once before evaluation. */
void kec_host_set_args(int argc, char **argv);

#endif /* KEC_HOST_H */
