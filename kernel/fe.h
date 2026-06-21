/*
** Copyright (c) 2020 rxi
**
** This library is free software; you can redistribute it and/or modify it
** under the terms of the MIT license. See `fe.c` for details.
*/

#ifndef FE_H
#define FE_H

#include <stdlib.h>
#include <stdio.h>

#define FE_VERSION "1.0"

typedef float fe_Number;
typedef struct fe_Object fe_Object;
typedef struct fe_Context fe_Context;
typedef fe_Object* (*fe_CFunc)(fe_Context *ctx, fe_Object *args);
typedef void (*fe_ErrorFn)(fe_Context *ctx, const char *err, fe_Object *cl);
typedef void (*fe_WriteFn)(fe_Context *ctx, void *udata, char chr);
typedef char (*fe_ReadFn)(fe_Context *ctx, void *udata);
typedef struct { fe_ErrorFn error; fe_CFunc mark, gc; } fe_Handlers;

enum {
  FE_TPAIR, FE_TFREE, FE_TNIL, FE_TNUMBER, FE_TSYMBOL, FE_TSTRING,
  FE_TFUNC, FE_TMACRO, FE_TPRIM, FE_TCFUNC, FE_TPTR
};

fe_Context* fe_open(void *ptr, int size);
void fe_close(fe_Context *ctx);
fe_Handlers* fe_handlers(fe_Context *ctx);
void fe_error(fe_Context *ctx, const char *msg);
fe_Object* fe_nextarg(fe_Context *ctx, fe_Object **arg);
int fe_type(fe_Context *ctx, fe_Object *obj);
int fe_isnil(fe_Context *ctx, fe_Object *obj);
void fe_pushgc(fe_Context *ctx, fe_Object *obj);
void fe_restoregc(fe_Context *ctx, int idx);
int fe_savegc(fe_Context *ctx);
void fe_mark(fe_Context *ctx, fe_Object *obj);
fe_Object* fe_cons(fe_Context *ctx, fe_Object *car, fe_Object *cdr);
fe_Object* fe_bool(fe_Context *ctx, int b);
fe_Object* fe_number(fe_Context *ctx, fe_Number n);
fe_Object* fe_string(fe_Context *ctx, const char *str);
fe_Object* fe_symbol(fe_Context *ctx, const char *name);
fe_Object* fe_cfunc(fe_Context *ctx, fe_CFunc fn);
fe_Object* fe_ptr(fe_Context *ctx, void *ptr);
fe_Object* fe_list(fe_Context *ctx, fe_Object **objs, int n);
fe_Object* fe_car(fe_Context *ctx, fe_Object *obj);
fe_Object* fe_cdr(fe_Context *ctx, fe_Object *obj);
void fe_write(fe_Context *ctx, fe_Object *obj, fe_WriteFn fn, void *udata, int qt);
void fe_writefp(fe_Context *ctx, fe_Object *obj, FILE *fp);
int fe_tostring(fe_Context *ctx, fe_Object *obj, char *dst, int size);
fe_Number fe_tonumber(fe_Context *ctx, fe_Object *obj);
void* fe_toptr(fe_Context *ctx, fe_Object *obj);
void fe_set(fe_Context *ctx, fe_Object *sym, fe_Object *v);
fe_Object* fe_read(fe_Context *ctx, fe_ReadFn fn, void *udata);
fe_Object* fe_readfp(fe_Context *ctx, FILE *fp);
fe_Object* fe_eval(fe_Context *ctx, fe_Object *obj);
fe_Object* fe_macroexpand1(fe_Context *ctx, fe_Object *obj);

/*
 * GWP-248: Optional instruction-budget enforcement.
 *
 * The eval() loop increments an internal counter on every entry. When
 * the counter exceeds the configured budget, fe_error("instruction budget
 * exceeded") fires and unwinds via the installed error handler.
 *
 * Default budget = 0 means "unlimited" (preserves the original Fe behavior
 * for the editor + REPL contexts). The scripted-mission sandbox runner sets
 * a non-zero budget per invocation and resets the counter before each run.
 */
void fe_set_instr_budget(fe_Context *ctx, int budget);
int  fe_get_instr_count(fe_Context *ctx);
void fe_reset_instr_count(fe_Context *ctx);

/*
 * GWP-233: Arena introspection.
 *
 * Sweeps the object slab and returns:
 *   - live_objects: count of slots that are not FE_TFREE (i.e. live or
 *     unreachable-but-not-yet-collected). Reflects current arena
 *     pressure as observed by the bump/freelist allocator.
 *   - total_objects: capacity of the slab (set at fe_open() time as
 *     `(arena_size - sizeof(fe_Context)) / sizeof(fe_Object)`).
 *
 * Each fe_Object is two machine words (16 bytes on 64-bit hosts;
 * 8 bytes on 32-bit hosts). Multiply by sizeof(fe_Object) (which
 * fe_object_size() exposes) to translate slot counts into bytes.
 *
 * Note: live_objects reflects the *current* heap, not a peak. To track
 * a peak across an evaluation, sample fe_arena_stats() repeatedly and
 * keep the maximum yourself. Sampling is O(total_objects) so it should
 * be done at coarse boundaries (between handler invocations, not
 * inside hot inner loops).
 *
 * Either out-pointer may be NULL if the caller only wants one value.
 */
void fe_arena_stats(fe_Context *ctx, int *live_objects, int *total_objects);

/* Size in bytes of a single arena slot. Constant for the lifetime of
 * the process; exposed so callers can convert slot counts to bytes
 * without having to know the internal struct layout. */
int fe_object_size(void);

/* Minimum arena size in bytes fe_open() can be safely called with: the size
 * of the context header (which fe_open subtracts off the front of the arena).
 * A buffer smaller than this underflows fe_open's internal size and faults
 * before any error handler exists. Embedders that take a caller-supplied
 * arena should reject buffers below this floor. Tracks GCSTACKSIZE. */
int fe_min_arena_bytes(void);

/* Read-only access to the interned-symbol list, for host-side introspection
 * (e.g. a `globals` primitive). The returned list and its pairs are LIVE
 * internal structure and a GC root — treat it as read-only and do not hand it
 * to Lisp directly; build a fresh list from it instead. */
fe_Object* fe_symbols(fe_Context *ctx);

/* Parameter list of a Lisp closure (FE_TFUNC) or macro (FE_TMACRO), for
 * host-side introspection (e.g. a `fn-params` primitive). Returns nil for a
 * built-in (cfunc/prim) or non-function. The returned list is LIVE internal
 * structure — copy it before handing it to Lisp. */
fe_Object* fe_fn_params(fe_Context *ctx, fe_Object *fn);

#endif
