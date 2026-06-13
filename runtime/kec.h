/*
** kec.h — KEC Lisp embedding API.
**
** This is the surface a host program (the `kec` CLI, or downstream the nOSh
** firmware) links against to embed KEC Lisp: open an interpreter, load KEC
** Core, evaluate source, and extend the Stdlib with its own C primitives via
** kec_bind_fe (host.h). One kec_State owns one Fe context + arena.
*/
#ifndef KEC_H
#define KEC_H

#include <stdio.h>
#include "fe.h"
#include "host.h"

typedef struct kec_State kec_State;

/* Open an interpreter: allocate `arena_bytes`, open Fe, install the error
** recovery handler, bind the host primitives for `profile`, and load Core.
** Returns NULL on allocation failure or if Core fails to load. */
kec_State *kec_open(size_t arena_bytes, kec_Profile profile);
void kec_close(kec_State *S);

/* Underlying Fe context — for downstream FFI extension (kec_bind_fe). */
fe_Context *kec_fe(kec_State *S);

/* Evaluate every top-level form. Returns 0 on success, 1 on error (message
** in kec_error). `out` (optional) receives the value of the last form. */
int kec_eval_string(kec_State *S, const char *src, fe_Object **out);
int kec_eval_file(kec_State *S, const char *path, fe_Object **out);

/* Parse-only validation: read every top-level form without evaluating.
** Returns 0 if the whole source reads cleanly, 1 on a syntax error
** (message in kec_error). Used by `kec build`. */
int kec_check_string(kec_State *S, const char *src);

/* Last error message, or "" if none. */
const char *kec_error(kec_State *S);

/* Read the numeric value of a global binding (e.g. a test fail count).
** Returns `dflt` if unbound or non-numeric. */
int kec_global_int(kec_State *S, const char *name, int dflt);

#endif /* KEC_H */
