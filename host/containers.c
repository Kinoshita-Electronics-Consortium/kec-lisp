/*
** containers.c — KEC Lisp container types: vectors and hash tables (ADR-0003).
**
** Both are FE_TPTR foreign objects. The frozen Fe kernel exposes fe_ptr/fe_toptr
** plus a single pair of mark/gc handler hooks, so new aggregate types need no
** kernel change. The fe_Object cell only holds a backing pointer (in its cdr);
** the actual storage — a vector's element array, a hash table's slot array —
** is a C struct that lives OUTSIDE the Fe arena, reached through that pointer.
** Element / key / value cells themselves are ordinary Fe objects in the arena.
**
** GC integration. One mark and one gc handler are installed on the context:
**   - mark handler: for each live container, fe_mark() every contained cell, so
**     vector elements and hash keys+values survive the sweep.
**   - gc handler:   when a container's FE_TPTR is collected (including at
**     fe_close, which sweeps everything), free its backing.
** Both are MAGIC-guarded: a foreign FE_TPTR that is not one of ours is left
** untouched. The standalone language creates no other ptr objects; the guard
** keeps the handlers safe if a downstream host (the firmware) later adds its own.
**
** Backing memory goes through a settable allocator (kec_set_container_allocator),
** defaulting to malloc/free, so the no-malloc device path can install an
** arena-bump allocator instead of libc malloc — this resolves ADR-0001's
** deferred container backing-memory concern (see ADR-0003).
**
** Equality / hashing of keys mirrors the language's own rules: numbers by value,
** symbols by identity (they are interned, so identity == name), strings by
** content. Pairs and other aggregates are not hashable (raising a clear error)
** because the language compares them by identity and a structural hash would
** risk non-termination on cyclic structure.
*/
#include "host.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Allocator seam (defaults to malloc/free).                          */
/* ------------------------------------------------------------------ */

static void *(*g_default_alloc)(size_t) = malloc;
static void (*g_default_free)(void *) = free;

void kec_set_container_allocator(void *(*alloc)(size_t), void (*free_)(void *)) {
    g_default_alloc = alloc ? alloc : malloc;
    g_default_free = free_ ? free_ : free;
}

void kec_host_state_set_container_allocator(kec_HostState *state,
                                            void *(*alloc)(size_t),
                                            void (*free_)(void *)) {
    state->container_alloc = alloc ? alloc : g_default_alloc;
    state->container_free = free_ ? free_ : g_default_free;
}

/* ------------------------------------------------------------------ */
/* Backing structs.                                                   */
/* ------------------------------------------------------------------ */

#define KEC_CMAGIC 0x4B454343u /* 'KECC' — guards foreign ptr objects */
#define KEC_VECTOR_MAX (1 << 24) /* exact-float ceiling; far past practical use */
#define KEC_HASH_KEYMAX 1024 /* string key compare/hash window (symbols/numbers exact) */

enum { KEC_KIND_VECTOR = 1, KEC_KIND_HASH = 2 };

typedef struct {
    unsigned magic;
    int kind;
    void *(*alloc)(size_t);
    void (*free_)(void *);
} CHeader;

static const char g_container_tag;

typedef struct {
    CHeader head;
    int len;
    fe_Object *items[1]; /* len cells, allocated inline */
} Vector;

enum { SLOT_EMPTY = 0, SLOT_USED = 1, SLOT_DEAD = 2 /* tombstone */ };

typedef struct {
    unsigned char state;
    fe_Object *key;
    fe_Object *val;
} HashSlot;

typedef struct {
    CHeader head;
    int count; /* live entries */
    int used; /* live + tombstones (probe-sequence occupancy) */
    int cap; /* slot count, a power of two */
    HashSlot *slots;
} Hash;

static CHeader *backing(fe_Context *ctx, fe_Object *obj) {
    CHeader *c;
    if (!fe_ptr_is_type(ctx, obj, &g_container_tag)) { return NULL; }
    c = fe_toptr(ctx, obj);
    if (!c) { return NULL; }
    return c;
}

static int checked_int_arg(fe_Context *ctx, fe_Object **args, const char *who) {
    double n = (double)fe_tonumber(ctx, fe_nextarg(ctx, args));
    char msg[96];
    if (!isfinite(n) || floor(n) != n || n < (double)INT32_MIN || n > (double)INT32_MAX) {
        snprintf(msg, sizeof msg, "%s: expected an integer", who);
        fe_error(ctx, msg);
    }
    return (int)n;
}

/* ------------------------------------------------------------------ */
/* GC handlers (installed once on the context).                       */
/* ------------------------------------------------------------------ */

static void container_mark(fe_Context *ctx, void *ptr) {
    CHeader *c = ptr;
    if (c && c->kind == KEC_KIND_VECTOR) {
        Vector *v = (Vector *)c;
        int i;
        for (i = 0; i < v->len; i++) {
            if (v->items[i]) { fe_mark(ctx, v->items[i]); }
        }
    } else if (c && c->kind == KEC_KIND_HASH) {
        Hash *h = (Hash *)c;
        int i;
        for (i = 0; i < h->cap; i++) {
            if (h->slots[i].state == SLOT_USED) {
                fe_mark(ctx, h->slots[i].key);
                fe_mark(ctx, h->slots[i].val);
            }
        }
    }
}

static void container_gc(fe_Context *ctx, void *ptr) {
    CHeader *c = ptr;
    (void)ctx;
    if (c) {
        if (c->kind == KEC_KIND_HASH) {
            Hash *h = (Hash *)c;
            if (h->slots) { c->free_(h->slots); }
        }
        c->free_(c);
    }
}

/* ------------------------------------------------------------------ */
/* Vectors.                                                           */
/* ------------------------------------------------------------------ */

static Vector *as_vector(fe_Context *ctx, fe_Object *obj, const char *who) {
    CHeader *c = backing(ctx, obj);
    if (c && c->kind == KEC_KIND_VECTOR) { return (Vector *)c; }
    fe_error(ctx, who);
    return NULL; /* unreachable: fe_error longjmps */
}

static Vector *alloc_vector(fe_Context *ctx, int len, fe_Object *init) {
    kec_HostState *state = kec_host_state(ctx);
    Vector *v;
    size_t bytes;
    int i;
    if (len < 0) { fe_error(ctx, "make-vector: negative length"); }
    if (len > KEC_VECTOR_MAX) { fe_error(ctx, "make-vector: length too large"); }
    bytes = sizeof(Vector) + (size_t)(len > 0 ? len - 1 : 0) * sizeof(fe_Object *);
    v = state->container_alloc(bytes);
    if (!v) { fe_error(ctx, "make-vector: out of memory"); }
    v->head.magic = KEC_CMAGIC;
    v->head.kind = KEC_KIND_VECTOR;
    v->head.alloc = state->container_alloc;
    v->head.free_ = state->container_free;
    v->len = len;
    for (i = 0; i < len; i++) { v->items[i] = init; }
    return v;
}

/* (make-vector n [init]) — a vector of n elements, each init (default nil). */
static fe_Object *h_make_vector(fe_Context *ctx, fe_Object *args) {
    int len = checked_int_arg(ctx, &args, "make-vector");
    fe_Object *init = fe_isnil(ctx, args) ? fe_bool(ctx, 0) : fe_nextarg(ctx, &args);
    int gc = fe_savegc(ctx);
    fe_Object *vec;
    fe_pushgc(ctx, init); /* keep init alive across the FE_TPTR alloc (may GC) */
    vec = fe_ptr_typed(ctx, alloc_vector(ctx, len, init), &g_container_tag);
    fe_restoregc(ctx, gc); /* pop init + vec ... */
    fe_pushgc(ctx, vec); /* ... re-root vec (its items are now reachable) */
    return vec;
}

/* (vector a b ...) — a vector of the given elements. */
static fe_Object *h_vector(fe_Context *ctx, fe_Object *args) {
    int n = 0, i, gc;
    fe_Object *p = args, *vec;
    Vector *v;
    while (!fe_isnil(ctx, p)) { n++; p = fe_cdr(ctx, p); }
    gc = fe_savegc(ctx);
    fe_pushgc(ctx, args); /* root every element cell across the alloc */
    v = alloc_vector(ctx, n, fe_bool(ctx, 0));
    p = args;
    for (i = 0; i < n; i++) { v->items[i] = fe_nextarg(ctx, &p); }
    vec = fe_ptr_typed(ctx, v, &g_container_tag);
    fe_restoregc(ctx, gc);
    fe_pushgc(ctx, vec);
    return vec;
}

/* (vector-ref v i) — element i (0-based). Errors out of range. */
static fe_Object *h_vector_ref(fe_Context *ctx, fe_Object *args) {
    Vector *v = as_vector(ctx, fe_nextarg(ctx, &args), "vector-ref: not a vector");
    int i = checked_int_arg(ctx, &args, "vector-ref");
    if (i < 0 || i >= v->len) { fe_error(ctx, "vector-ref: index out of range"); }
    return v->items[i];
}

/* (vector-set! v i x) — set element i to x; returns x. Errors out of range. */
static fe_Object *h_vector_set(fe_Context *ctx, fe_Object *args) {
    Vector *v = as_vector(ctx, fe_nextarg(ctx, &args), "vector-set!: not a vector");
    int i = checked_int_arg(ctx, &args, "vector-set!");
    fe_Object *x = fe_nextarg(ctx, &args);
    if (i < 0 || i >= v->len) { fe_error(ctx, "vector-set!: index out of range"); }
    v->items[i] = x; /* x becomes reachable via the (rooted) vector; no alloc here */
    return x;
}

/* (vector-length v) — element count. */
static fe_Object *h_vector_length(fe_Context *ctx, fe_Object *args) {
    Vector *v = as_vector(ctx, fe_nextarg(ctx, &args), "vector-length: not a vector");
    return fe_number(ctx, (fe_Number)v->len);
}

/* (vector? x) — true iff x is a vector. */
static fe_Object *h_vector_p(fe_Context *ctx, fe_Object *args) {
    CHeader *c = backing(ctx, fe_nextarg(ctx, &args));
    return fe_bool(ctx, c && c->kind == KEC_KIND_VECTOR);
}

/* ------------------------------------------------------------------ */
/* Hash tables (open addressing, linear probe, grow on load).         */
/* ------------------------------------------------------------------ */

static Hash *as_hash(fe_Context *ctx, fe_Object *obj, const char *who) {
    CHeader *c = backing(ctx, obj);
    if (c && c->kind == KEC_KIND_HASH) { return (Hash *)c; }
    fe_error(ctx, who);
    return NULL; /* unreachable */
}

static unsigned key_hash(fe_Context *ctx, fe_Object *k, int *ok) {
    int t = fe_type(ctx, k);
    *ok = 1;
    if (t == FE_TNUMBER) {
        fe_Number n = fe_tonumber(ctx, k);
        unsigned u = 0;
        if (n == 0) { n = 0; } /* fold -0.0 into +0.0 so == keys hash alike */
        memcpy(&u, &n, sizeof n < sizeof u ? sizeof n : sizeof u);
        return u * 2654435761u;
    }
    if (t == FE_TSYMBOL) {
        uintptr_t p = (uintptr_t)k; /* interned: identity is name equality */
        return (unsigned)((p >> 4) * 2654435761u);
    }
    if (t == FE_TSTRING) {
        char buf[KEC_HASH_KEYMAX];
        unsigned h = 2166136261u; /* FNV-1a over the printed bytes */
        int i;
        fe_tostring(ctx, k, buf, sizeof buf);
        for (i = 0; buf[i]; i++) { h = (h ^ (unsigned char)buf[i]) * 16777619u; }
        return h;
    }
    *ok = 0;
    return 0;
}

static int key_equal(fe_Context *ctx, fe_Object *a, fe_Object *b) {
    int ta = fe_type(ctx, a);
    if (ta != fe_type(ctx, b)) { return 0; }
    if (ta == FE_TNUMBER) { return fe_tonumber(ctx, a) == fe_tonumber(ctx, b); }
    if (ta == FE_TSYMBOL) { return a == b; }
    if (ta == FE_TSTRING) {
        char ba[KEC_HASH_KEYMAX], bb[KEC_HASH_KEYMAX];
        fe_tostring(ctx, a, ba, sizeof ba);
        fe_tostring(ctx, b, bb, sizeof bb);
        return strcmp(ba, bb) == 0;
    }
    return 0;
}

/* Locate key's slot. Returns the index; *found=1 if key is present, else the
** index where it would be inserted (preferring a tombstone). Errors on an
** unhashable key. With grow-on-load there is always an empty slot to stop at. */
static int hash_index(fe_Context *ctx, Hash *h, fe_Object *key, int *found) {
    int ok;
    unsigned hv = key_hash(ctx, key, &ok);
    unsigned mask = (unsigned)h->cap - 1u;
    int i, first_dead = -1, probes;
    if (!ok) { fe_error(ctx, "hash: unhashable key (use a number, string, or symbol)"); }
    i = (int)(hv & mask);
    *found = 0;
    for (probes = 0; probes <= h->cap; probes++) {
        HashSlot *s = &h->slots[i];
        if (s->state == SLOT_EMPTY) { return first_dead >= 0 ? first_dead : i; }
        if (s->state == SLOT_DEAD) {
            if (first_dead < 0) { first_dead = i; }
        } else if (key_equal(ctx, s->key, key)) {
            *found = 1;
            return i;
        }
        i = (int)((unsigned)(i + 1) & mask);
    }
    if (first_dead >= 0) { return first_dead; }
    fe_error(ctx, "hash: table full");
    return -1; /* unreachable */
}

static Hash *alloc_hash(fe_Context *ctx) {
    kec_HostState *state = kec_host_state(ctx);
    Hash *h = state->container_alloc(sizeof(Hash));
    int cap = 8, i;
    if (!h) { fe_error(ctx, "make-hash-table: out of memory"); }
    h->slots = state->container_alloc((size_t)cap * sizeof(HashSlot));
    if (!h->slots) {
        state->container_free(h);
        fe_error(ctx, "make-hash-table: out of memory");
    }
    h->head.magic = KEC_CMAGIC;
    h->head.kind = KEC_KIND_HASH;
    h->head.alloc = state->container_alloc;
    h->head.free_ = state->container_free;
    h->count = 0;
    h->used = 0;
    h->cap = cap;
    for (i = 0; i < cap; i++) {
        h->slots[i].state = SLOT_EMPTY;
        h->slots[i].key = NULL;
        h->slots[i].val = NULL;
    }
    return h;
}

static void hash_grow(fe_Context *ctx, Hash *h) {
    int newcap = h->cap * 2, oldcap = h->cap, i;
    HashSlot *old = h->slots;
    HashSlot *ns = h->head.alloc((size_t)newcap * sizeof(HashSlot));
    if (!ns) { fe_error(ctx, "hash: out of memory"); }
    for (i = 0; i < newcap; i++) {
        ns[i].state = SLOT_EMPTY;
        ns[i].key = NULL;
        ns[i].val = NULL;
    }
    h->slots = ns;
    h->cap = newcap;
    h->used = 0;
    h->count = 0;
    for (i = 0; i < oldcap; i++) {
        if (old[i].state == SLOT_USED) {
            int found;
            int idx = hash_index(ctx, h, old[i].key, &found); /* re-hashable: was inserted */
            h->slots[idx].state = SLOT_USED;
            h->slots[idx].key = old[i].key;
            h->slots[idx].val = old[i].val;
            h->count++;
            h->used++;
        }
    }
    h->head.free_(old);
}

/* (make-hash-table) — a new empty hash table. */
static fe_Object *h_make_hash(fe_Context *ctx, fe_Object *args) {
    (void)args;
    return fe_ptr_typed(ctx, alloc_hash(ctx), &g_container_tag);
}

/* (hash-set! h k v) — associate k -> v; returns v. */
static fe_Object *h_hash_set(fe_Context *ctx, fe_Object *args) {
    Hash *h = as_hash(ctx, fe_nextarg(ctx, &args), "hash-set!: not a hash table");
    fe_Object *key = fe_nextarg(ctx, &args);
    fe_Object *val = fe_nextarg(ctx, &args);
    int found, idx;
    if ((h->used + 1) * 4 >= h->cap * 3) { hash_grow(ctx, h); } /* keep load < 0.75 */
    idx = hash_index(ctx, h, key, &found);
    if (!found) {
        if (h->slots[idx].state == SLOT_EMPTY) { h->used++; }
        h->count++;
        h->slots[idx].state = SLOT_USED;
        h->slots[idx].key = key;
    }
    h->slots[idx].val = val; /* key/val reachable via the (rooted) table; no fe alloc */
    return val;
}

/* (hash-ref h k [default]) — value for k, or default (nil) when absent. */
static fe_Object *h_hash_ref(fe_Context *ctx, fe_Object *args) {
    Hash *h = as_hash(ctx, fe_nextarg(ctx, &args), "hash-ref: not a hash table");
    fe_Object *key = fe_nextarg(ctx, &args);
    fe_Object *dflt = fe_isnil(ctx, args) ? fe_bool(ctx, 0) : fe_nextarg(ctx, &args);
    int found;
    int idx = hash_index(ctx, h, key, &found);
    return found ? h->slots[idx].val : dflt;
}

/* (hash-has? h k) — true iff k is present. */
static fe_Object *h_hash_has(fe_Context *ctx, fe_Object *args) {
    Hash *h = as_hash(ctx, fe_nextarg(ctx, &args), "hash-has?: not a hash table");
    fe_Object *key = fe_nextarg(ctx, &args);
    int found;
    hash_index(ctx, h, key, &found);
    return fe_bool(ctx, found);
}

/* (hash-del! h k) — remove k; returns t if it was present, else nil. */
static fe_Object *h_hash_del(fe_Context *ctx, fe_Object *args) {
    Hash *h = as_hash(ctx, fe_nextarg(ctx, &args), "hash-del!: not a hash table");
    fe_Object *key = fe_nextarg(ctx, &args);
    int found;
    int idx = hash_index(ctx, h, key, &found);
    if (!found) { return fe_bool(ctx, 0); }
    h->slots[idx].state = SLOT_DEAD; /* tombstone; used stays, count drops */
    h->slots[idx].key = NULL;
    h->slots[idx].val = NULL;
    h->count--;
    return fe_bool(ctx, 1);
}

/* (hash-count h) — number of live entries. */
static fe_Object *h_hash_count(fe_Context *ctx, fe_Object *args) {
    Hash *h = as_hash(ctx, fe_nextarg(ctx, &args), "hash-count: not a hash table");
    return fe_number(ctx, (fe_Number)h->count);
}

/* (hash-keys h) — a fresh list of the live keys (unspecified order). */
static fe_Object *h_hash_keys(fe_Context *ctx, fe_Object *args) {
    fe_Object *ho = fe_nextarg(ctx, &args);
    Hash *h = as_hash(ctx, ho, "hash-keys: not a hash table");
    fe_Object *res = fe_bool(ctx, 0);
    int gc = fe_savegc(ctx), i;
    fe_pushgc(ctx, ho); /* the table roots its own keys */
    fe_pushgc(ctx, res);
    for (i = 0; i < h->cap; i++) {
        if (h->slots[i].state == SLOT_USED) {
            res = fe_cons(ctx, h->slots[i].key, res);
            fe_restoregc(ctx, gc); /* keep the gcstack bounded over a large table */
            fe_pushgc(ctx, ho);
            fe_pushgc(ctx, res);
        }
    }
    return res;
}

/* (hash-table? x) — true iff x is a hash table. */
static fe_Object *h_hash_p(fe_Context *ctx, fe_Object *args) {
    CHeader *c = backing(ctx, fe_nextarg(ctx, &args));
    return fe_bool(ctx, c && c->kind == KEC_KIND_HASH);
}

/* ------------------------------------------------------------------ */
/* Registration.                                                      */
/* ------------------------------------------------------------------ */

void kec_containers_register(fe_Context *ctx) {
    if (fe_register_ptr_type(ctx, &g_container_tag, container_mark, container_gc) != 0) {
        fe_error(ctx, "container foreign pointer type registration failed");
    }

    kec_bind_fe(ctx, "make-vector", h_make_vector);
    kec_bind_fe(ctx, "vector", h_vector);
    kec_bind_fe(ctx, "vector-ref", h_vector_ref);
    kec_bind_fe(ctx, "vector-set!", h_vector_set);
    kec_bind_fe(ctx, "vector-length", h_vector_length);
    kec_bind_fe(ctx, "vector?", h_vector_p);

    kec_bind_fe(ctx, "make-hash-table", h_make_hash);
    kec_bind_fe(ctx, "hash-set!", h_hash_set);
    kec_bind_fe(ctx, "hash-ref", h_hash_ref);
    kec_bind_fe(ctx, "hash-has?", h_hash_has);
    kec_bind_fe(ctx, "hash-del!", h_hash_del);
    kec_bind_fe(ctx, "hash-count", h_hash_count);
    kec_bind_fe(ctx, "hash-keys", h_hash_keys);
    kec_bind_fe(ctx, "hash-table?", h_hash_p);
}
