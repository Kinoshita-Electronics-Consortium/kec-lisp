---
title: "Field Notes: The Art of the Metaobject Protocol"
description: Transferable design lessons for KEC Lisp mined from Kiczales, des Rivières & Bobrow's AMOP — open implementation, protocol design, reflection, and metacircular bootstrapping.
---

> Reading notes on Kiczales, des Rivières & Bobrow, *The Art of the Metaobject
> Protocol* (MIT Press, 1991), mined for **transferable design lessons for KEC
> Lisp**. We are **not** building an object system. AMOP is about *how to design
> an extensible language substrate* — open implementation, protocol design,
> reflection, and metacircular bootstrapping — and that is exactly the design
> space KEC lives in: a frozen kernel, a self-hosted Lisp prelude, a portable C
> primitive surface, and an FFI seam through which the firmware extends the
> language.

**How to read this.** Each note cites a **printed book page** (`p. NN`), states
the insight, and ties it to a concrete KEC layer/seam/file. Applicability tags:

- **Direct** — adopt the pattern more or less as-is.
- **Analogous** — the shape transfers; the mechanics differ.
- **Aspirational** — worth it only if/when KEC grows in that direction.
- **Avoid** — object-system machinery with no KEC analog; noted so we don't cargo-cult it.

Source: `Art of Metaobject Protocol.pdf` (330 pp.). PDF↔book offset: PDF page = book page + 5.

---

## The thesis in one paragraph (why this book is relevant to us)

Traditional language design treats the language as an immutable black box — a
fixed "semantics" you build *on top of* but never *inside*. AMOP's move is to
**reify the language's own implementation as ordinary, inspectable, overridable
objects**, so users can adjust the language toward their program *incrementally,
locally, and without forking the implementation* (Intro, pp. 1–8). KEC already
embodies the same bet without classes: a small frozen Fe kernel + C primitives as
the bedrock, a standard library written *in KEC Lisp* on top, and one FFI seam
(`kec_bind_fe`) through which both the CLI and the KN-86 firmware extend the
language. AMOP is the most rigorous treatment of *how to design those seams well*
— and that's the value here.

---

## Top transferable lessons (cross-cutting synthesis)

Ranked by value to KEC. Each links to the detailed notes below.

1. **Macros are sugar; semantics live in callable functions beneath them.**
   The single most-repeated structural lesson (Ch 1 §1.3 p. 17, Ch 3 §3.3 p. 95,
   Ch 5 §5.4 p. 145). `defclass` is "magic" only at the top — it canonicalizes
   syntax and expands into a plain `ensure-class` call on regular data.
   **KEC action:** every defining macro (`00-def`, any future `defcart`/`defmission`
   sugar over FFI) should do *only* literal-shape normalization and expand into
   ordinary function calls. Keep the callable protocol invokable without the
   sugar, so it stays REPL-debuggable and cheap (macroexpansion-at-eval costs GC
   stack on the device).

2. **Classify every FFI primitive as functional or procedural** (Ch 4 §4.2 pp. 110–111).
   *Functional* = exposes a value to compute (pure, order-free → cacheable,
   mediatable, sandbox-friendly: `type-of`, lookups). *Procedural* = exposes a
   procedure that must run (effects, ordering matters → not cacheable, privileged:
   draw/sound/save). **KEC action:** annotate each `host/host.c` and firmware
   primitive with its kind in `docs/ffi-bridge.md`; bias SANDBOX toward functional
   primitives whose results the runtime can interpose on.

3. **Memoization is a property you design in, not bolt on** (Ch 1 §1.9 p. 45; Ch 4 §4.4 pp. 125–131).
   Split a hot operation into a slow, open *"compute a plan from stable inputs"*
   part (cache this) and a *"execute the plan on today's args"* part (run every
   time) — the discriminating-function / inline-cache pattern. The cache key must
   be the **complete** set of functional inputs, and invalidation must watch them.
   **KEC caution:** because `set` and top-level `let` can redefine globals at any
   time, any symbol-resolution/dispatch cache must be invalidated by global-binding
   mutation, or correctness breaks silently.

4. **Layer the protocol: publish sub-operations, not one monolith** (Ch 4 §4.3 pp. 119–121).
   Lower layers = more power, harder to use; higher layers = easy, safer; ship
   **both** and implement the high-level entry point *in terms of* the low-level
   ones so an override propagates upward for free. **KEC action:** don't expose only
   a monolithic `eval` — keep read / macroexpand / resolve / apply as distinct
   seams. Publish a high-level Lisp API in `core/` for cart authors and the
   low-level C `kec_bind_fe` seam for firmware; don't force either audience to the
   wrong altitude.

5. **Reflection is read-only first, and the reader API is a *contract*, not the data structure** (Ch 2 §2.1 pp. 49–51).
   "Fair use rules": introspection accessors return a **fresh, documented-shape
   value** the caller must treat as read-only — never a handle into live internals.
   Ask the runtime "what's defined" rather than re-parsing `.lsp` files; ship the
   API, let tools (REPL completer, SYS browser) be built on top. **KEC action:** a
   small `(bound? sym)` / `(globals)` host primitive returning fresh copies; specify
   equality + printed form up front for any handle-like value (KEC already compares
   pairs by identity).

6. **Metacircular bootstrap: keep a minimal frozen base; the load order *is* the dependency DAG** (App C pp. 269–274; App D).
   Closette is an object system written almost entirely in Lisp over a tiny
   primitive core; it avoids infinite regress by **hand-building a few well-founded
   base cases** and a **finite, ordered startup sequence**. Bootstrap is
   all-or-nothing. **KEC validation:** this is precisely `core/`-in-Lisp over the
   frozen Fe kernel, the hardcoded `CORE_SRCS` order (`00-def → … → 70-sort`), the
   `mkembed` baked prelude, and the no-malloc `kec_open_with_arena` that must load
   Core or **return NULL cleanly**. Keep that clean-fail seam well-tested
   (`tests/c/test_arena.c`).

7. **The read/write line is the capability line → profiles** (Ch 2 §2.5 p. 70; Ch 4 §4.2 p. 111; Ch 5 §5.3.1 pp. 142–144).
   Reads are safe-everywhere; writes/effects need a deliberate boundary. A profile
   is exactly "which subprotocols are bound into this context." **KEC action:**
   document `KEC_PROFILE_SANDBOX` vs `KEC_PROFILE_FULL` as *contracts* (what's
   guaranteed present / absent); introspective reads → SANDBOX, reflective writes &
   device effects → FULL/firmware.

8. **A good extension seam has four properties — use them as a review checklist** (Ch 3 §3.9 p. 106):
   **Portability** (works on every build — desktop *and* device — without
   implementation-specific hooks), **Scope control** (an override affects only the
   overrider's context/cart, not the whole system), **Operation control** (override
   one operation without disturbing others), **Efficiency** (the override doesn't
   break the arena/GC performance model). **KEC action:** run every new FFI seam or
   profile past these four; codify in `docs/boundary.md` / `docs/ffi-bridge.md`.

9. **Constrain overrides to preserve invariants; specify what may be overridden** (Ch 3 §3.4 pp. 79–80; Ch 4 §4.2.1–4.2.2 pp. 111–113; Ch 6 entry format).
   Document each seam as a contract addressed to the *overrider*: signature, default
   behavior, "what is undefined," and which load-bearing functions must **not** be
   shadowed. Prefer **marking a fact at definition time** over inferring it later
   (Ch 2 §2.3.4 p. 64). **KEC action:** classify Core/host symbols safe-to-shadow vs
   do-not-shadow (a cart redefining `map` could corrupt the baked prelude); put the
   *why* of kernel deltas (`set` vs `=`, top-level `let`) in a Remarks block so
   nobody "fixes" a deliberate decision.

---

## Introduction — Open Implementation & the Region of Designs (book pp. 1–9)

The Introduction frames the whole program: elegance and efficiency are in tension
only if the language is a fixed black box. Metaobject protocols dissolve the
tension by letting users select a point in a *region* of language designs around a
sensible default — the same default-plus-controlled-variation philosophy KEC's
profiles and FFI seam express.

### Languages as black boxes vs. open implementations
- **Where:** p. 1 (Introduction)
- **Insight:** Traditional designs present immutable "black-box" behaviors (semantics); metaobject protocols "open languages up," letting users adjust the language's behavior from within rather than building only on top of a frozen surface.
- **Why it matters for KEC Lisp:** Names KEC's actual posture: the Fe kernel is frozen, but `core/` (Lisp) and the `kec_bind_fe` seam are the "opening" through which behavior is adjusted/extended. Frame KEC's extensibility story explicitly as open implementation in `docs/boundary.md`.
- **Applicability:** Analogous

### No single implementation is universally appropriate → support a region
- **Where:** pp. 4–6 ("The Problems We Faced": compatibility, extensibility, efficiency)
- **Insight:** The same construct wants different implementations in different programs (two-slot `x,y` vs. a large sparse slot set), so "no single implementation strategy will ever be universally appropriate." The fix is to support a *region* of designs around a default, not one rigid point.
- **Why it matters for KEC Lisp:** Justifies KEC shipping a strong default Core/host while letting the firmware re-bind primitives for the device's needs. The desktop (8192 GC stack) vs device (256) split is one such "region" already.
- **Applicability:** Analogous

### Two criteria that make reflective adjustment usable: incremental + robust
- **Where:** p. 7 (reflective techniques; reification of program fragments as metaobjects)
- **Insight:** For "open the language" to be practical, adjustments must be (i) **incremental & local** — expressed at a high level of abstraction, changing only a small region — and (ii) **robust** — effective without breaking other programs. Reification (program fragments become first-class objects) is what enables both.
- **Why it matters for KEC Lisp:** A litmus test for any KEC extension point: can the firmware change *one* behavior locally without a global rewrite, and without breaking unrelated carts? If a seam fails either test, it's the wrong seam.
- **Applicability:** Direct

### Four design criteria for the substrate: robustness, abstraction, ease of use, efficiency
- **Where:** p. 8 ("Structure of the Book" preamble / design criteria)
- **Insight:** The authors commit to four criteria: **Robustness** (moving the language for one program must not adversely affect others), **Abstraction** (you shouldn't need to know complete implementation details to adjust it), **Ease of use** (the adjusted language stays natural), **Efficiency** (an augmented program needn't run slower than a traditional one).
- **Why it matters for KEC Lisp:** A ready-made rubric for KEC API/seam review, complementing Ch 3's four extension-seam properties. "Efficiency" is load-bearing on a Pi Zero 2 W: an extension must not defeat the arena/no-heap-churn model.
- **Applicability:** Direct

### The audience split = our audience split
- **Where:** p. 2 (twofold purpose: language designers; programmers/engineers; reflection people)
- **Insight:** The book deliberately serves both *language implementors* and *ordinary users* of the extended language, because a good protocol must satisfy both at once.
- **Why it matters for KEC Lisp:** Mirrors KEC's two audiences — the runtime/firmware engineers (who bind primitives in C) and cart authors (who write Lisp). Design docs should address both explicitly; the high/low layering in lesson #4 is how you serve them without compromise.
- **Applicability:** Analogous

---

## Chapter 1 — How CLOS Is Implemented (book pp. 13–46)

The chapter builds "Closette," a working subset implementation of CLOS, to show that the implementation is itself made of ordinary first-class objects (metaobjects) the user can later reach. The key architectural move is a deliberate **three-layer structure** — a thin macro layer (syntactic sugar) over a glue layer (names→metaobjects) over a base layer (metaobjects directly) — so that surface syntax is decoupled from the real machinery, and "magic" forms like `defclass` reduce to plain function calls on inspectable data. Performance is consciously deferred to a later chapter, with memoization flagged as the universal optimization.

### Three-layer decomposition: sugar / glue / base
- **Where:** p. 17 (§1.3 "Representing Classes"), recapped p. 46 (§1.10 "Summary")
- **Insight:** Every defining form is split into three strata: a **macro-expansion layer** (thin syntactic veneer that maps user syntax to the glue layer), a **glue layer** that maps *names* to metaobjects (e.g. `find-class`, `ensure-class`), and a **base layer** that traffics directly in the metaobjects themselves. `defclass` is "magic" only at the top; underneath it is an ordinary call to `ensure-class` on plain data.
- **Why it matters for KEC Lisp:** This is exactly KEC's `kernel → core → host → runtime` stacking, and the lesson is to keep each layer a thin, honest translation of the one below. Macros (`mac` in core, `45-quasiquote`/`40-ctrl`) should be sugar that expands to calls on lower-layer primitives, never the place where real semantics live — so behavior stays testable and replaceable at the layer that owns it.
- **Applicability:** Direct

### Macro as a thin entry point, not a semantics hiding place
- **Where:** pp. 18–19 (§1.3.1 "The defclass Macro"), p. 35 (§1.6.1 "The defgeneric Macro"), pp. 37–38 (§1.7.1 "The defmethod Macro")
- **Insight:** `defclass`/`defgeneric`/`defmethod` each macro-expand into a single `ensure-*` call after canonicalizing their arguments (`canonicalize-direct-superclasses`, etc.). The macro's only jobs are to quote/normalize literal syntax and hand a clean property-list/data structure to a real function — "the bulk of the macro-expansion work is carried out by `canonicalize-…` procedures," i.e. functions, not macro bodies.
- **Why it matters for KEC Lisp:** When KEC's firmware or core adds a defining macro (e.g. a `defcart`/`defmission` sugar over FFI primitives), push all real work into ordinary functions the macro *calls*, leaving the macro to do only literal-shape normalization. This keeps the expansion debuggable in the REPL and lets the same functions be invoked directly, bypassing the macro — valuable on a device where macroexpansion-at-eval costs GC stack.
- **Applicability:** Direct

### Canonicalize messy surface syntax into uniform internal data immediately
- **Where:** pp. 19–21 (§1.3.2–§1.3.4 "Direct Superclasses / Direct Slots / Class Options")
- **Insight:** The first thing the implementation does is convert irregular user syntax (a slot spec can carry `:initform`, `:initarg`, `:reader`, `:accessor` in any mix) into one regular property-list form — collecting multiple `:reader`/`:writer` options into one list, wrapping `:initform` in a zero-arg `:initfunction` closure captured in the lexical environment. All downstream code sees one canonical shape.
- **Why it matters for KEC Lisp:** A strong pattern for KEC's `host/` parsing primitives and any cart-manifest reader: normalize once at the boundary, then let every later stage assume the regular form. The `:initform → :initfunction` trick (defer a value by wrapping it in a thunk that captures its environment) is directly reusable for any "evaluate this later in the right scope" need in core or in mission FFI.
- **Applicability:** Direct

### Glue layer = a name→object registry, kept in one place
- **Where:** pp. 21–22 (§1.3.5 "ensure-class", §1.3.6 "Initializing Class Metaobjects")
- **Insight:** `find-class`/`ensure-class` are the *only* mapping from names to class metaobjects, backed by one global `class-table` hash. Redefinition, "no class named S" errors, and registration all funnel through this single seam, so name resolution policy lives in exactly one spot.
- **Why it matters for KEC Lisp:** KEC's runtime (`kec.h`) and the FFI seam already centralize "name → C function" via `kec_bind_fe`. The lesson is to keep *all* name resolution (symbols → primitives, cart IDs → loaded carts, save-slot names → storage) funneled through one registry each, so capability-tier enforcement and error messaging have a single chokepoint — which directly supports the SANDBOX vs FULL profile model.
- **Applicability:** Direct

### Bind capability by what you register; split a privileged interface from the user-facing one
- **Where:** p. 39 (§1.7.2 "Accessor Methods"), pp. 46–47 (§1.10 + Ch. 2 opener)
- **Insight:** Accessor methods are generated by the implementation calling lower-level `add-reader-method`/`add-writer-method` directly — the same operations a user *could* do, but exposed to the system at a layer the casual user never touches. Ch. 2's opener makes the stance explicit: a deliberate set of fixtures (`make-instance`, `slot-value`, `class-of`, `standard-object`) is "in the hands of the user," while `standard-class`/`standard-method` and internal functions stay backstage.
- **Why it matters for KEC Lisp:** The conceptual backbone of KEC's profile tiers and the firmware-vs-language split: "what you bind into a context is what it's allowed to do." Deciding *which* primitives `host/host.c` exposes vs. which the firmware keeps private, and which internal helpers never get a Lisp name, is the same on-stage/backstage curation — capability is a registration decision, not a language feature.
- **Applicability:** Direct

### "About the program" vs "of the program": keep the meta-level a separate object graph
- **Where:** pp. 16–17 (§1.2–1.3, "metaobjects … *about* the program rather than … *of* the program"), Figure 1.1
- **Insight:** A sharp line: instances like `door` are objects *of* the program's domain; metaobjects (class/generic-function/method objects) are objects *about* the program, living in a parallel, bidirectionally-linked graph that's "normally hidden backstage."
- **Why it matters for KEC Lisp:** Even without an object system, cleanly separate *runtime data* (a cart's game state) from *descriptive metadata about the program* (cart manifest, FFI version, the bound-primitive table, profile). Keep that descriptor graph as ordinary inspectable data — it's what later enables a REPL `describe`/introspection story without reflection hooks scattered through the interpreter.
- **Applicability:** Analogous

### Errors live at the glue seam with full context
- **Where:** p. 22 (§1.3.6 `find-class` errorp branch), p. 29 (§1.5.3 `slot-value` / `slot-location` errors)
- **Insight:** Error signaling concentrates at resolution boundaries: `find-class` raises "No class named S"; `slot-location` raises "The slot S is missing from the class S"; each message carries the specific name/class at the point the missing thing was requested.
- **Why it matters for KEC Lisp:** Matches KEC's small error vocabulary and the `35-error` core module: raise at the lookup seam (symbol-not-bound, primitive-not-permitted-in-this-profile, save-slot-missing) with the concrete name in the message, rather than letting a `nil` propagate into a confusing downstream failure. On a handheld with no debugger, the message *is* the debugging tool.
- **Applicability:** Direct

### Representation choice: a private sentinel beats a parallel flag (the "unbound" value)
- **Where:** pp. 27–30 (§1.5.1–§1.5.4 "Determining the Class / Allocating Storage / Accessing Bindings / Initializing")
- **Insight:** Instance storage is a deliberately abstract interface (`allocate-instance`, `slot-contents`, `slot-location`), and "unbound" is a unique private sentinel (`secret-unbound-value`) stored in the slot — not a separate flag — so `slot-boundp` is just an `eq` test. The representation makes the common operation cheap.
- **Why it matters for KEC Lisp:** A reusable embedded idiom: use one private sentinel instead of parallel boolean flags to mark "absent/unbound," keeping storage flat and tests to one `is`/`eq`. Relevant to KEC save-state and any fixed-size cell pool — flat, arena-friendly storage with sentinel markers avoids extra allocation and matches "no GC heap churn."
- **Applicability:** Analogous

### Self-implementation bottoms out on a few primitives you must NOT redefine
- **Where:** p. 18 (§1.3 note on accessors / `slot-value`), p. 47 (Ch. 2 opener: fixtures not part of the "on-stage" set)
- **Insight:** Closette implements CLOS largely *in* CLOS (class metaobjects are instances of `standard-class`, etc.), but a small kernel of operations (`allocate-instance`, `class-of`, slot accessors) is bootstrapped in plain Lisp and treated as bedrock. The system is reflective "all the way down" only until it reaches that frozen floor.
- **Why it matters for KEC Lisp:** Directly mirrors KEC: `core/` is written *in* KEC Lisp over a **frozen Fe kernel**, with a hardcoded `00-def → … → 70-sort` order that bottoms out on C primitives. The rule: be self-hosting where it buys expressiveness, but keep an explicit, frozen, minimal kernel the rest is forbidden to redefine — and document the load order as the dependency contract (CMakeLists already does).
- **Applicability:** Direct

### Performance is a separate concern: memoize at stable seams, after correctness
- **Where:** p. 45 (§1.9 "A Word About Performance"), Exercise 1.1
- **Insight:** Ship a "woefully inefficient" but correct implementation first, then name memoization as the universal optimization: cache expensive meta-computations (method applicability, slot locations) because they recur identically and slot locations "never change" once computed. The exercise asks the reader to identify the *invalidation conditions*.
- **Why it matters for KEC Lisp:** Get correctness green first (KEC already does — full ctest suite), then memoize only at seams whose inputs are stable (symbol→primitive resolution, a parsed `kec build`-inlined cart, sort-key precompute in `70-sort`). The hard part is invalidation; on the fixed arena, prefer caches whose lifetime is bounded by a clear reset point (cart-load / mission boundary) so a cache never outlives its validity.
- **Applicability:** Analogous

### Write the hot internal helpers iteratively, not recursively
- **Where:** pp. 24–25 (§1.3.7 `compute-class-precedence-list`, `topological-sort`), p. 43 (§1.8.3 `apply-methods` via `dolist`)
- **Insight:** Internal traversals lean on iterative idioms (`mapappend`, `dolist`, `remove-duplicates`, explicit topological sort) rather than deep recursion, even though the surface language is recursion-friendly — so arbitrarily long lists of superclasses/methods don't blow the control stack.
- **Why it matters for KEC Lisp:** *Already* KEC's stated convention — core list/sequence functions are "written iteratively on purpose so a library call won't exhaust the GC stack" (compile-time `GCSTACKSIZE`, 256 on device). AMOP independently validates it: any library/runtime traversal over unbounded input must be iterative on a small-stack target. Treat as a hard rule for new `10-list`/`50-hof`/`70-sort` additions.
- **Applicability:** Direct

---

## Chapter 2 — Introspection and Analysis (book pp. 47–70)

The chapter argues that the *first* step in exposing a language's internals is read-only introspection: shipping a documented, portable set of reader functions over the program's own structure so users can build their own browsers and analysis tools instead of parsing source or reverse-engineering the implementation. It then shows two consumers — *regeneration* (reconstruct a `defclass` form from live metaobjects) and *analysis* (find all subclasses/generic functions) — before crossing into write territory with programmatic class creation built on the same documented surface. The governing discipline is "fair use rules" (pp. 50–51): the reader API hands out a *contract*, not the implementation's actual data structures.

### Reflection beats parsing the source file
- **Where:** p. 49 (§2.1 "Introducing Class Metaobjects")
- **Insight:** The authors reject two non-portable ways to answer "what classes exist" — tracking `defclass` forms, or reading source — in favor of a documented function (`find-class`, `class-of`) that taps the implementation's own existing record. The information is *already* in the system; the only question is whether there's a sanctioned, portable way to ask.
- **Why it matters for KEC Lisp:** Tooling that needs "what's defined" (a REPL completer, a SYS browser, a cart inspector) should ask the runtime, not re-parse `.lsp`. `runtime/kec.h` + host already own the global environment; a small `(bound? sym)` / `(globals)` host primitive turns that internal knowledge into a portable read surface instead of forcing every tool to shadow-track definitions.
- **Applicability:** Direct

### "Fair use rules": the reader API is a contract, not the data structure
- **Where:** pp. 50–51 (§2.1, "fair use rules" + Exercise 2.1)
- **Insight:** Accessors like `class-direct-subclasses` return a *fresh* list the user must treat as read-only — no order/duplicate assumptions, no mutation, no `eq` identity across calls. This decouples what the user sees (a documented value) from how the implementor stores it (maybe nothing — it could be recomputed), preserving implementor freedom.
- **Why it matters for KEC Lisp:** The single most transferable lesson of the chapter. Any KEC introspection primitive (env contents, a function's param list, type metadata) should return a freshly-built copy with a documented shape, never a handle into the live `kec_State`/arena. That keeps arena internals safe from mutation and lets the kernel change representation without breaking tools — the firewall the frozen-kernel discipline wants.
- **Applicability:** Direct

### Internal access already exists; the work is making it *portable* and *documented*
- **Where:** p. 49 (§2.1, "internal to Closette … adding these internal functions to the documented language")
- **Insight:** The implementation already calls these accessors privately; "exposing" them is mostly a documentation-and-stability commitment, not new machinery. Promotion from internal helper to public protocol is a contract decision.
- **Why it matters for KEC Lisp:** Fe/host already have C-level access to bindings, cfunc pointers, types. The cost of `type-of`-style introspection is the *stability promise*, not the plumbing. Be deliberate about which internals graduate to the documented FFI surface — once a cart or the firmware depends on it, it's frozen like the kernel.
- **Applicability:** Direct

### Ship the API, not the browser
- **Where:** p. 48 (§2.1 intro), p. 58 (§2.2.5 Summary)
- **Insight:** Browsers have historically been "tightly coupled to internal aspects of the language implementation and not portable." The fix is layered: ship documented reader functions, and *users* write browsers/analysis tools on top, portably.
- **Why it matters for KEC Lisp:** The KN-86's on-device SYS/LAMBDA tabs, the REPL, and any cart-authoring inspector are all "browsers." Expose a clean reader API at the host seam and those tools live in `core/` (Lisp) or the firmware — they never reach into the kernel. Matches KEC's bottom-up layering: introspection primitives in `host/`, tools in KEC Lisp above them.
- **Applicability:** Direct

### Regeneration as a correctness test for the reader API
- **Where:** pp. 53–55 (§2.2.2 "Regenerating Class Definitions")
- **Insight:** `generate-defclass` reconstructs the *original source form* purely from live metaobjects. If you can round-trip the definition out of introspection alone, your reader surface is provably complete — every field is reachable.
- **Why it matters for KEC Lisp:** A strong acceptance test: can you reconstruct a `(def name (fn (args) …))` from whatever the reader API exposes? `kec build` already does source-level inlining; a "regenerate from runtime state" capability would both validate the introspection surface and give the SDK a debugging/serialization tool. Test it like the C-arena seam (`tests/c/`) — round-trip is the assertion.
- **Applicability:** Analogous

### Distinguish source/direct facts from computed/inherited facts
- **Where:** pp. 50, 55 (§2.2.3; `class-direct-slots` vs `class-slots`, `class-direct-superclasses` vs `class-precedence-list`)
- **Insight:** The protocol offers paired readers: the *direct* (literally written) and the *effective* (full computed/inherited result), and the inherited display labels each slot with where it came from. Two questions, two functions.
- **Why it matters for KEC Lisp:** KEC has the same split: a symbol bound in the *current* environment vs. resolved through the global `core/` prelude. Introspection should let a tool ask "defined here, or inherited from Core?" and report provenance — invaluable for the `KEC_CORE_DIR` path where a live Core edit layers *over* the embedded prelude (a deleted def lingers; a provenance reader would surface exactly that).
- **Applicability:** Analogous

### Enumerate "everything" by reachability from a known root
- **Where:** pp. 52, 62 (§2.2.1 `subclasses*`; §2.3.2 `all-generic-functions` walks the class hierarchy)
- **Insight:** "List all X" starts at a root (`standard-object`, `t`) and transitively walks documented links; the reachability guarantee ("every method appears among the direct methods of … `t`") is what makes the enumeration complete.
- **Why it matters for KEC Lisp:** Enumeration tools ("list every binding," "every function reachable from a cart's entry points") should be traversals over documented links from a known root, not scrapes of a hidden table. Argues for exposing the *global environment as an iterable* at the host seam, with `core/`-level code computing "all definitions" — completeness lives in the data, not ad-hoc bookkeeping.
- **Applicability:** Analogous

### Identity & printed-form semantics of any handle must be specified
- **Where:** p. 50 (§2.1, compare metaobjects with `eq`), p. 59 (same for generic-function/method metaobjects)
- **Insight:** Before users build anything, the protocol pins down that metaobjects compare by `eq` (identity) and gives them readable printed forms (`#<Standard-Class COLOR-RECTANGLE …>`). Introspection isn't just readers — it's a stable identity + printable representation.
- **Why it matters for KEC Lisp:** Connects to a documented KEC gotcha: `=`/`is` compare pairs *by identity*, strings structurally, numbers by value. If KEC exposes any handle-like introspection value (an environment, a function object), specify its equality and printed form up front, or tools built on it will be subtly non-portable. Decide identity semantics *as part of* shipping the primitive.
- **Applicability:** Direct

### Mark facts at definition time rather than infer them later
- **Where:** pp. 64–66 (§2.3.4 `reader-method-p` / `writer-method-p`; Exercise 2.4)
- **Insight:** Whether a method is an auto-generated accessor isn't stored, so the tool *infers* it (a 1-specializer, slot-named method). The authors flag this as fragile and prefer the cleaner alternative: have the machinery *mark* the object at creation so the predicate is a direct lookup.
- **Why it matters for KEC Lisp:** A caution for KEC's reader surface. If a tool needs something the language doesn't record ("is this a macro vs a function," "defined in Core vs by a cart"), prefer recording the fact at definition time over inferring it later. Marking is cheap; inference is brittle and couples tools to incidental structure — relevant when deciding what metadata `def`/`mac` should stamp onto bindings.
- **Applicability:** Analogous

### Bounded query parameters (a `ceiling`) for scoped introspection
- **Where:** pp. 63, 65 (§2.3.3 `relevant-generic-functions (class ceiling)`, `&key elide-accessors-p`)
- **Insight:** A general traversal becomes *useful* with a scoping argument (upper bound on the precedence list) plus a noise filter. The reflective query is parameterized for the actual question, not "give me everything."
- **Why it matters for KEC Lisp:** On a memory- and screen-constrained device, an unbounded "dump every binding" is both a GC-stack hazard and useless UX. Introspection primitives should take scope/limit/filter args (globals-only, names-matching-prefix, exclude-Core) so the REPL completer or SYS browser asks a bounded question — consistent with the iterative-on-purpose, GC-stack-aware Core style.
- **Applicability:** Direct

### Programmatic construction is the write-half of the same protocol
- **Where:** pp. 66–69 (§2.4 "Programmatic Creation of New Classes", `make-programmatic-class`)
- **Insight:** Writing one `defclass` per valid combination is "tedious and wasteful" when most combinations are never instantiated. The fix is a *function* that builds the object on demand from computed args, through the same documented protocol the readers expose — the constructor is just the writer half, name-keyed via `find-class`.
- **Why it matters for KEC Lisp:** When the set of "things" is combinatorial/data-driven (KN-86 missions, generated carts, procedural content), provide a *constructor function* taking computed args rather than hand-written surface forms for each. KEC already leans this way — `mac`/quasiquote build forms programmatically, the firmware constructs runtime objects via FFI. Keep that programmatic path a first-class documented seam equal to the syntactic one, not a back door.
- **Applicability:** Analogous

### Read access is safe; write access needs a deliberate boundary
- **Where:** p. 70 (§2.5 Summary, theatre metaphor); pp. 51, 68 (write rules)
- **Insight:** The chapter keeps almost everything "backstage" (read-only introspection that can't perturb behavior) and is markedly more cautious crossing to writes — programmatic creation comes with ground rules about not mutating the lists you pass in. The read/write line is where the safety thinking concentrates.
- **Why it matters for KEC Lisp:** Maps cleanly onto `KEC_PROFILE_SANDBOX` vs `KEC_PROFILE_FULL`. Introspective *reads* (what's bound, arity, type) are natural sandbox-safe primitives; introspective/reflective *writes* (define-at-runtime, rebind, construct) belong in FULL or behind the firmware's controlled seam. Use the profile mechanism to enforce "read is everywhere, write is privileged."
- **Applicability:** Direct

---

## Chapter 3 — Extending the Language (book pp. 71–106)

Chapter 3 demonstrates how a user *extends* CLOS by subclassing standard metaobjects and overriding specific protocol generic-functions (class precedence, slot inheritance, slot access, instance allocation, default-initargs) while inheriting all unaltered behavior via `call-next-method`. The recurring design pattern — reify the default behavior as a named, overridable operation with a sensible standard method, let users select a point in a "design space" by overriding *one* operation and inheriting the rest, and keep mechanism separate from policy — is the transferable gold; the chapter closes (§3.9, p. 106) naming the four criteria that make such a seam good: **scope control, operation control, portability, efficiency**. The OO machinery itself is largely non-transferable.

### Reify default behavior as a named operation with a standard method
- **Where:** p. 80 (§3.4.1 "Alternative Class Precedence Lists"), reinforced p. 85 (§3.5.1)
- **Insight:** The fixed property "class precedence list" is replaced by a generic function `compute-class-precedence-list` whose *standard method* reproduces the original behavior verbatim; users override that one function (for Flavors/Loops ordering) while everything downstream is unchanged. A hardcoded decision becomes "computed by a function we provide a standard method for."
- **Why it matters for KEC Lisp:** The core seam-design lesson for `host/` primitives and `kec_bind_fe`: a behavior the firmware might vary (how a slot/save-state name resolves, a default lookup) should be a *named, separately-bindable* function with a stock implementation, not inlined into kernel C, so the firmware can re-register one name without forking the kernel.
- **Applicability:** Direct

### Specialize the policy, inherit the mechanism (call-next-method)
- **Where:** p. 73 (§3.1), p. 86 (§3.5.1), pp. 101–102 (§3.8)
- **Insight:** Overrides rarely reimplement the whole operation — they add an `:after`/`:before` sliver or `call-next-method` and post-process. "The standard method will run … counted classes inherit all the standard behavior … but can also add their own." The user changes *only the portion* they care about.
- **Why it matters for KEC Lisp:** Our extension points should let firmware *wrap*, not replace. An FFI primitive the firmware overrides should be able to call through to the stock `host/` implementation (the "next method") rather than copy it — keeping device behavior a thin delta over the shipped, tested layer.
- **Applicability:** Analogous

### A protocol carves a bounded "design space" the user picks a point in
- **Where:** p. 74 (§3.2 "Terminology"), p. 79 (§3.4), p. 106 (§3.9 Summary)
- **Insight:** Extensions are *variant languages* incrementally defined over the base: "the new language is incrementally defined in terms of the original … only a portion of the user's program is expressed in that new language." The protocol bounds how far a user can deviate (a precedence list must still include `standard-object` and `t`) so the implementor keeps guarantees.
- **Why it matters for KEC Lisp:** SANDBOX vs FULL profiles already *are* this — each profile is a "point in the design space" of capability. Design each new seam so an override stays *within* invariants the runtime relies on (arena bounds, GC-stack discipline), giving firmware freedom without breaking the substrate.
- **Applicability:** Direct

### Constrain overrides to preserve implementor invariants
- **Where:** pp. 79–80 (§3.4, requirements (i)–(iii) + the slot-location memoization constraint)
- **Insight:** Before opening the precedence list, the authors impose explicit limits: the result must be a permutation of the superclasses, must include `standard-object` and `t`, and "must not change once computed" — because slot locations are memoized off it. They knowingly trade flexibility for efficiency + a coherent range of variants.
- **Why it matters for KEC Lisp:** When exposing any overridable seam, document and enforce the invariants the runtime memoizes/assumes (fixed object pool, no heap growth, bounded GC stack). A firmware override that would violate "no malloc in hot path" or "arena resets at boundaries" must be structurally impossible, not just discouraged.
- **Applicability:** Direct

### Mechanism/policy split — the "on-stage / backstage" metaphor
- **Where:** p. 83 (§3.4.2, "participatory theatre"), p. 106 (§3.9)
- **Insight:** The protocol lets the audience (user) "go on-stage" and alter the play (the variant language) while the producers (implementor) still control "the lighting, or the sets." Users affect *what* happens, not the underlying machinery.
- **Why it matters for KEC Lisp:** A clean restatement of the layering contract: kernel/ + host/ are backstage (frozen Fe VM, portable C); core/ and firmware-registered primitives are the on-stage surface. Keep the seam so on-stage extensions can never reach backstage internals.
- **Applicability:** Analogous

### Composable orthogonal extensions
- **Where:** p. 105 (§3.9, `both-slots-class` from `dynamic-slot-class` + `class-slot-class`), p. 106
- **Insight:** Because two extensions override *different* operations (one slot-storage, one slot-allocation), a user can inherit from both and get the union. "Operation and scope control mean that conceptually orthogonal language extensions can be naturally composed." Orthogonality enables composition.
- **Why it matters for KEC Lisp:** If each firmware capability (graphics, sound, save, CIPHER) is an independent set of named primitives touching disjoint concerns, they compose without interference — the device gets the union by binding all of them. Argues for keeping FFI groups orthogonal and namespaced rather than one monolithic device primitive.
- **Applicability:** Analogous

### Precompute/memoize behind a protocol seam (finalize-inheritance)
- **Where:** p. 93 (§3.6.1 `finalize-inheritance`), p. 80 (slot-location memoization), pp. 91–92 (default-initargs)
- **Insight:** Expensive inheritance computations are done *once* at a defined "finalize" point and stored, so per-instance creation reads cached results. The protocol guarantees finalization happens before instances are made — which is what lets the override be both flexible and cheap.
- **Why it matters for KEC Lisp:** Pattern for any future config/resolution layer: resolve at a load/finalize boundary (cart-load, context-open) and cache, rather than recomputing per call — mirrors the arena reset "at cart-load and mission-instance boundaries." Extension hooks should fire at the finalize boundary, not the hot path.
- **Applicability:** Aspirational

### Make extensions observable by wrapping, not patching (monitoring)
- **Where:** pp. 97–98 (§3.7.1 "Monitoring Slot Access", `monitored-class` with `:before` methods)
- **Insight:** A complete instrumentation layer (log every slot read/write/bound/makunbound) is added purely by defining `:before` methods — zero change to the access mechanism, fully opt-in per subclass, removable by not using the subclass.
- **Why it matters for KEC Lisp:** Validates a tracing/observability strategy for the FFI seam: a debug profile could bind wrapping versions of host primitives that log then delegate, with shipped `host/host.c` untouched. Diagnostics as a *composed layer*, not a compile flag threaded through the kernel.
- **Applicability:** Analogous

### The convenience surface is separable from the protocol
- **Where:** pp. 76–77 (§3.3), p. 95 (revised `defclass` + `canonicalize-defclass-options`)
- **Insight:** The user-facing `defclass` macro is deliberately thin — canonicalizes options, funnels into `ensure-class` → `make-instance`. Adding a `:metaclass` option is "only modest changes" because the macro is policy-free plumbing over the real protocol; macro and mechanism evolve independently.
- **Why it matters for KEC Lisp:** Keep core/ macros (the ergonomic surface, e.g. `00-def`) as thin sugar over host/runtime primitives, so the convenience layer can change without touching the seam. A firmware-facing macro can be re-skinned without re-validating the underlying C primitive.
- **Applicability:** Direct

### Two distinct extension kinds: change behavior vs add new behavior
- **Where:** p. 106 (§3.9)
- **Insight:** The chapter separates *modifying* existing default behavior (a different precedence list) from *adding* genuinely new behavior (slot attributes, dynamic allocation). Both use the same subclass-and-override mechanism, but they're different intents the design must support distinctly.
- **Why it matters for KEC Lisp:** Our seam must support both: firmware *replacing* a stock host primitive (override) and firmware *registering a brand-new* primitive the language never shipped (graphics/sound/CIPHER). `kec_bind_fe` handles both today; keep that symmetry explicit and documented in `docs/ffi-bridge.md`.
- **Applicability:** Direct

### Four criteria for a good extension seam
- **Where:** p. 106 (§3.9 Summary)
- **Insight:** What makes an extension protocol good: **Portability** (documented, supported by all implementations, "without resorting to implementation-specific details or hooks"), **Scope control** (the variant affects only the user's own classes), **Operation control** (override one operation without disturbing others), **Efficiency** (memoization etc. survive the extension).
- **Why it matters for KEC Lisp:** A ready-made checklist for any new FFI seam or profile: portable across desktop+device builds, scoped so a firmware override doesn't leak into other contexts/carts, operation-granular, and free from breaking the arena/GC efficiency model. Codify in the boundary/FFI docs.
- **Applicability:** Direct

### OO-specific machinery to skip
- **Where:** pp. 78–82 (precedence-list *rules*), pp. 84–89 (slot-attribute impl), pp. 99–104 (dynamic-slot tables)
- **Insight:** Depth-first vs topological precedence ordering, effective-slot coalescing, per-instance slot bucket/hash storage — all intrinsic to an inheritance-based object system.
- **Why it matters for KEC Lisp:** KEC will not gain classes, inheritance, or instance-slot storage; these illustrate the *pattern* (override one operation) but their substance has no KEC analog. Mine for the meta-pattern, not the mechanics.
- **Applicability:** Avoid

---

## Chapter 4 — Protocol Design (book pp. 107–136)

The crown jewel. The chapter distills the "art" of designing extensible protocols using generic-function invocation as a running example. Three load-bearing ideas: (1) the **functional vs. procedural** distinction — whether a protocol exposes a *value to compute* or *a procedure to run* — which governs memoizability and what override is sane; (2) **layered protocols**, where a heavyweight operation is defined in terms of smaller, individually-overridable subprotocols so users intervene at the narrowest sensible layer; and (3) **performance via memoization**, splitting a protocol into a slow/open/recomputable part and a fast/cached part so extensibility doesn't cost the hot path.

### Functional vs. procedural is the first design axis
- **Where:** pp. 110–111 (§4.2 "Functional and Procedural Protocols")
- **Insight:** A *functional* protocol exposes a value to be computed (e.g. a class-precedence list) and says nothing about *when/how often* it runs, so results are memoizable and the implementor keeps execution freedom; a *procedural* protocol exposes the procedure itself and stipulates that it runs — producing effects directly — so it can be hooked but not freely cached.
- **Why it matters for KEC Lisp:** Every FFI primitive registered via `kec_bind_fe` (in `host/host.c` and the firmware's device layer) is implicitly one or the other; classify each. A pure query (`type-of`, a lookup) is functional (cacheable, side-effect-free, sandbox-safe); a draw/sound/save primitive is procedural (must run, ordering matters, not cacheable). Documenting this per-primitive stops the FFI seam from promising caching it can't keep.
- **Applicability:** Direct

### Functional results are "made visible," procedural are "in the user's hands"
- **Where:** p. 111 (§4.2, top)
- **Insight:** Functional protocols limit the power handed out — the result is seen only through "the mediation of other parts of the system," so the implementor can add caching/monitoring/invalidation around it; procedural protocols are "direct … in the hands of the user," more powerful but harder to constrain.
- **Why it matters for KEC Lisp:** The capability argument for the profile tiers (`host/host.h`). FULL-only primitives (file/system) are the *procedural, direct-power* ones; SANDBOX should be biased toward *functional, mediated* primitives whose results the runtime can interpose on. Prefer exposing a value the runtime hands back over a procedure that reaches into the world, when a primitive could be either.
- **Applicability:** Direct

### Memoizability is a property you design in
- **Where:** pp. 110–111 (§4.2), p. 125 (§4.4 "Improving Performance")
- **Insight:** Because functional protocols don't restrict *when* they run, the implementor can "monitor those limited parts of the context that might invalidate any results previously cached." Memoization possibility follows directly from the functional style and keeping inputs explicit and observable.
- **Why it matters for KEC Lisp:** On a Pi Zero 2 W, caching hot lookups (symbol resolution, Core-function dispatch, expensive host queries) is the main performance lever. Design those seams *functionally* — pure function of explicit, observable inputs — so a cache layer can be bolted on without rewriting callers. Hidden mutable global state forfeits safe memoization.
- **Applicability:** Direct

### Procedural protocols can be split so part is still memoizable
- **Where:** pp. 125–126 (§4.4.1 "Effective Method Functions"), p. 131 (§4.5)
- **Insight:** Even an inherently procedural operation can be refactored into "a memoizable part and a part": `apply-methods` splits into a functional `compute-effective-method-function` (depends only on the gf + applicable methods → cacheable) plus the residual direct-execution path.
- **Why it matters for KEC Lisp:** The transferable trick for the interpreter: factor any hot procedural operation into "compute a plan from stable inputs" (cache) + "execute the plan against this call's arguments" (run). E.g. resolving which Core/host function a symbol denotes (stable → cache) vs. invoking it on today's args (run every time). The curry-and-cache pattern, ideal for a tree-walker re-traversing the same forms.
- **Applicability:** Direct

### Layered protocols: define the big operation in terms of small overridable ones
- **Where:** pp. 119–121 (§4.3 "Layered Protocols")
- **Insight:** A large operation (`apply-generic-function`) is split into pieces (`compute-applicable-methods-using-classes`, `method-more-specific-p`, `apply-methods`, `apply-method`, `extra-function-bindings`) so users override the narrowest layer meeting their need. Lower layers = more powerful access; higher layers = easier fallback.
- **Why it matters for KEC Lisp:** The design pattern for the `kernel → core → host → runtime` stack and any future hook points. Don't expose only a monolithic `eval`; expose the sub-operations (read, macroexpand, resolve, apply) so a cart author or the firmware can intervene at exactly one layer. KEC already does a milder version by writing `core/` over a small `host/` C surface — keep that discipline when adding hooks.
- **Applicability:** Direct

### Lower layers = power + difficulty; higher layers = convenience + safety; ship both
- **Where:** pp. 119–120 (§4.3)
- **Insight:** The layers trade off explicitly: lower = more powerful/general but harder to use correctly and "more unrelated to the aspect to be changed"; higher = focused/easier but less powerful. Good design offers *both*, letting users meet their need at the right altitude.
- **Why it matters for KEC Lisp:** Argues for a layered FFI/extension story: a high-level, hard-to-misuse Lisp API in `core/` for cart authors, and a lower-level C `kec_bind_fe` seam (`docs/ffi-bridge.md`) for firmware needing raw power. Don't force device authors to C, nor cart authors into unsafe territory — publish the layer each audience should touch.
- **Applicability:** Direct

### Higher layers are a fallback built on lower ones
- **Where:** p. 120 (§4.3)
- **Insight:** "Higher-level protocols are a fallback strategy … they give the user more complete power" — and the high-level op is *literally implemented by calling* the low-level ones, so overriding a low layer automatically changes behavior seen through the high layer.
- **Why it matters for KEC Lisp:** When KEC grows a hook system, implement the convenient high-level entry point *in terms of* the granular ones (ideally `core/` Lisp), so overriding a primitive propagates upward for free — no parallel code paths to keep in sync. The embedded-Core-in-binary model (`tools/mkembed.c`) makes this cheap: high-level helpers are Lisp, low-level seams are C.
- **Applicability:** Direct

### Specify behavior as restrictions, in terms of overridable methods
- **Where:** p. 111 (§4.2.1 "Documenting Generic Functions vs Methods")
- **Insight:** "The specification should be phrased in terms of restrictions on the behavior of generic functions or … their standard methods." A standard-method spec governs all its methods (and constrains user-defined ones); a generic-function spec doesn't restrict user methods. Which you specify decides how much freedom users get.
- **Why it matters for KEC Lisp:** In `docs/language.md`, `docs/boundary.md`, the FFI contract, frame each primitive as "here is the guarantee that holds no matter how you redefine around it" vs. "here is default behavior you may replace." The kernel deltas (`set` is assignment, top-level `let` binds globally) are exactly *restrictions on standard behavior* — document new seams the same way.
- **Applicability:** Direct

### Decide deliberately whether a standard method may be overridden
- **Where:** pp. 112–113 (§4.2.2 "Overriding the Standard Method")
- **Insight:** Some protocols must let users *override* the standard primary method (supplement isn't enough); others must *prohibit* it because the standard method "is required to invoke `call-next-method`" / does load-bearing work. Before/after methods only *supplement*; the designer must decide per operation and document it.
- **Why it matters for KEC Lisp:** For KEC's redefinition story (top-level `let`/`set` can redefine Core functions), classify each Core/host symbol: safe-to-shadow vs. load-bearing-do-not-shadow. Functions the runtime depends on (GC-safe iteration in `core/10-list.lsp`, error machinery in `35-error.lsp`) are "prohibit override" in spirit; mark them, lest a cart redefining `map` corrupt the baked-in prelude.
- **Applicability:** Analogous

### One principled extension seam beats N special-cased primitives (`extra-function-bindings`)
- **Where:** pp. 116–119 (§4.2.3)
- **Insight:** Rather than bake one feature into the standard method, the authors add a *general* hook — `extra-function-bindings` returns `(name . fn)` pairs spliced into the method body's lexical scope, "a place to put implementation-specific code … user methods are free to add whatever new bindings they wish." One open seam subsumes many specific features.
- **Why it matters for KEC Lisp:** Prefer one principled seam over many bespoke primitives. The single `kec_bind_fe` seam is already this in spirit (one mechanism, both CLI and firmware extend through it). When a new capability is requested, ask "can the existing seam carry it?" before widening the C surface; a narrow, GC-safe, well-understood seam beats a growing pile of builtins on a memory-bounded device.
- **Applicability:** Direct

### Memoize the fast path, keep the slow path open (discriminating function)
- **Where:** pp. 128–131 (§4.4.3 "Discriminating Functions", §4.4.4)
- **Insight:** The optimized design caches a per-gf *discriminating function*: first call computes classes→effective-method via the slow path and stores it keyed by argument classes; later calls hit the table and skip applicable-method computation. The slow path stays fully present for cache misses.
- **Why it matters for KEC Lisp:** The canonical inline-cache / memoized-dispatch pattern for the tree-walker. For repeated evaluation of the same forms, cache the resolved target keyed by a cheap stable key (symbol identity / arg shape), falling back to full resolution on miss — correctness intact, steady state fast on the Pi Zero 2 W. The cache must observe its invalidation inputs (redefinition).
- **Applicability:** Analogous

### Cache invalidation is bounded by watching the functional inputs
- **Where:** p. 129 (§4.4.4), p. 131 (§4.5)
- **Insight:** Memoization is sound only because the cached value "is based only on the classes of the arguments" — a small, explicit, observable input set. The discriminating function depends only on the gf's class and method set, so the implementor knows exactly what flushes the cache. "Memoization is not always possible with procedural protocols."
- **Why it matters for KEC Lisp:** Any KEC cache (symbol resolution, dispatch, host-query results) is only as safe as its *enumerated* invalidation triggers. Because `set` and top-level `let` can redefine globals at any time, a resolution cache's key must include — or be invalidated by — global-binding mutation. Design the cache key from the *complete* functional input set, or correctness breaks silently.
- **Applicability:** Direct

### Reuse one set of basic operations across functional and procedural framings
- **Where:** p. 132 (§4.5 summary; Exercise 4.5)
- **Insight:** The same operations (`apply-generic-function`, `apply-method`, `compute-effective-method-function`) serve as *both* a procedure (compute-and-do, possibly precomputed) *and* a value (return a function that does the work). "The procedure can be done once and cached, or moved off the critical path by precomputing it."
- **Why it matters for KEC Lisp:** Build KEC's core operations as small composable pieces that can be *either* invoked directly *or* returned as a closure to cache/precompile. `kec build` (inlines `load` forms, parse-checks, emits one `.kec`) is already a "precompute / move off critical path" move in this spirit — extend that thinking to runtime dispatch, not just the bundler.
- **Applicability:** Analogous

---

## Chapters 5–6 — Concepts; Generic Functions & Methods (book pp. 137–242)

Chapter 5 builds the MOP's conceptual core: a set of *metaobjects* wired by an inheritance lattice, plus the central move (§5.4) of making the friendly surface macros — `defclass`/`defmethod`/`defgeneric` — *expand into calls on an underlying functional protocol* (`ensure-class`, `ensure-generic-function`, `make-method-lambda`). §5.5 decomposes the whole into independent *subprotocols* (initialization, finalization, slot-access, invocation, dependent-maintenance), each a documented contract of overridable generic functions. Chapter 6 was **skimmed** (reference dictionary, ~80 pp.): each entry is **SYNTAX / ARGUMENTS / VALUES / PURPOSE / METHODS / REMARKS**, with rationale in PURPOSE and REMARKS.

### Surface macro expands into a functional protocol
- **Where:** p. 145 (§5.4 "Processing of the User Interface Macros")
- **Insight:** `defclass`/`defmethod`/`defgeneric` are *not* the semantic primitives — each macro normalizes its surface syntax (canonicalizing slot specs, capturing the lexical environment for `:initform`/method bodies) and expands into a call to a plain function (`ensure-class`, `ensure-generic-function`) that does the work. Macro owns syntax; function owns semantics; cleanly split.
- **Why it matters for KEC Lisp:** The exact layering KEC should adopt at its `mac` seam: a user-facing macro desugars into ordinary calls into `core/` stdlib or `host/` C primitives, never burying logic in the expansion. The macro captures/normalizes; the callable beneath does the work and stays independently testable and callable without the sugar.
- **Applicability:** Direct

### Canonicalization happens in the macro, before the protocol is called
- **Where:** pp. 146–149 (§5.4.2 "The defclass Macro")
- **Insight:** `defclass` converts each slot spec into a *canonicalized slot specification* and reduces class options to keyword args before handing them to `ensure-class`; the messy surface form is flattened to one regular, fully-explicit argument shape the functional layer consumes uniformly.
- **Why it matters for KEC Lisp:** KEC macros should do all the irregular work — defaulting, shorthand expansion, list-shape normalization — at expansion time, so the underlying core/host functions receive one canonical form. Quasiquote (`` ` ``/`,`/`,@`) is the natural tool for emitting these normalized calls. Keeps the callable protocol small and total.
- **Applicability:** Direct

### Thread the lexical environment through the expansion (emit thunks, not raw forms)
- **Where:** p. 145, pp. 147–152 (§5.4 / Figures 5.1–5.4)
- **Insight:** `:initform` forms and method bodies must evaluate in the *lexical scope of the macro form*, so the macro wraps them in zero-argument functions/lambdas that close over the surrounding environment before they reach `ensure-class`/`make-method-lambda`. The protocol receives thunks, not raw forms.
- **Why it matters for KEC Lisp:** Any KEC macro that defers evaluation (lazy init, deferred mission/cart handlers, CIPHER fragments) must capture the call-site environment the same way — emit a closure, not an unevaluated s-expr later `eval`'d in the wrong scope. With top-level `let` binding globally and `set` as assignment, scope mistakes are easy to make and hard to see; thunk-at-expansion is the safe pattern.
- **Applicability:** Direct

### One big protocol decomposed into independent subprotocols
- **Where:** p. 153, pp. 153–161 (§5.5 "Subprotocols")
- **Insight:** Rather than one monolithic "object protocol," the design is sliced into separate, self-contained subprotocols — initialization, class finalization, instance-structure/slot-access, gf invocation, dependent-maintenance — each with its own small set of generic functions, its own contract, its own override points. A user extends only the slice they care about.
- **Why it matters for KEC Lisp:** The KEC layer stack should expose capability as several narrow protocols rather than one giant FFI blob: a string protocol, a math protocol, an I/O protocol, a sys protocol. The firmware's device primitives (graphics / sound / save / missions / CIPHER) are naturally separate subprotocols bound through the same `kec_bind_fe` seam — each independently swappable and testable.
- **Applicability:** Direct

### A profile = which subprotocols a context gets (specified vs implementation-specific)
- **Where:** pp. 142–144 (§5.3.1 "Implementation and User Specialization")
- **Insight:** The MOP draws an explicit line between *specified* behavior (portable, guaranteed) and *implementation-specific* behavior, and bounds what a program may override (`make-instance` on specified classes may not be redefined; certain methods must call `call-next-method`). Capability is scoped by an explicit, documented contract, not by what happens to be reachable.
- **Why it matters for KEC Lisp:** KEC's `KEC_PROFILE_SANDBOX` vs `KEC_PROFILE_FULL` made principled: a profile is exactly "which subprotocols (file/sys vs. pure) are bound into this context." Document each profile as a contract — what's guaranteed present, what may be absent — so cart authors target SANDBOX and only the firmware adds FULL/device tiers.
- **Applicability:** Direct

### A protocol entry is a contract written for the overrider
- **Where:** p. 163 (Ch. 6 intro); pp. 164–166 (`add-dependent`, `add-direct-method` entries)
- **Insight:** Each generic function is documented in a fixed shape — **SYNTAX, ARGUMENTS, VALUES, PURPOSE, METHODS, REMARKS** — stating what the operation guarantees, which methods are provided, and crucially *what an extender may and may not change* ("This method cannot be overridden beyond …", "The results are undefined if …"). The spec addresses the person writing a new method, not just the caller.
- **Why it matters for KEC Lisp:** When KEC documents an extensible operation (a `host` primitive, an FFI seam the firmware overrides, a `core` hook), follow the same template: signature, args, return contract, default behavior, and an explicit "what you may override / what is undefined." `docs/ffi-bridge.md` and `docs/boundary.md` are the right homes; gives firmware authors a precise override contract instead of folklore.
- **Applicability:** Direct

### Rationale lives in dedicated REMARKS prose, not buried in code
- **Where:** p. 165 (`add-direct-method` REMARKS), p. 163 (Ch. 6 intro)
- **Insight:** Several entries carry a separate REMARKS section explaining *why* the operation exists and how it relates to siblings, keeping design intent adjacent to but distinct from the mechanical signature.
- **Why it matters for KEC Lisp:** KEC's protocol docs should separate "what it does" (signature/args/values) from "why it's shaped this way" (a Remarks/Notes block) — the same split CLAUDE.md enforces between kernel deltas and their justification. For seams like `set`-vs-`=` or top-level-`let`-binds-globally, the *why* is what stops a future maintainer from "fixing" a deliberate decision.
- **Applicability:** Analogous

### Default-method-plus-override is the mechanism (no class system required)
- **Where:** pp. 140–141 (§5.3, Table 5.1); pp. 157–159 (§5.5.3 `compute-slots`/`slot-value-using-class`, `ordered-class`)
- **Insight:** Extensibility comes from a *standard default method* users override for their case — subclass to get an `ordered-class` whose `compute-slots` sorts slots, layering custom behavior over `call-next-method` to the standard one. The inheritance lattice exists only to provide "here's the default; specialize to override."
- **Why it matters for KEC Lisp:** The transferable idea — **not** "add classes" — is "ship a working default behind every seam and let a higher layer override it." KEC's embedded `core` should provide a complete default prelude that the firmware (or the `KEC_CORE_DIR` dev overlay) *layers over* — which is precisely how the prototyping fast path already works. Bake a sane default; make override a first-class, documented move.
- **Applicability:** Analogous

---

## Appendices C–D — Living with Circularity; Working Closette (book pp. 269–316)

Appendix C diagnoses how a system implemented in terms of itself (CLOS-in-CLOS) avoids infinite regress at bootstrap: it separates *bootstrapping* issues (the chicken-and-egg of creating the first classes/generic functions before the machinery that makes them exists) from *metastability* issues (self-referential method-lookup and slot-access calls that would loop forever at steady state), and resolves each by deliberately grounding the recursion in a small set of hand-built base cases. Appendix D is the full Closette source — a complete simplified CLOS bootstrapped almost entirely in Lisp on a tiny kernel of primitive instance/slot access (**skimmed**, not read in full). Combined lesson for KEC: a self-hosted layer can be small and elegant *if* its load order is a genuine dependency DAG and a deliberately minimal set of operations stays primitive (in C) to terminate the recursion.

### Two kinds of circularity, named and separated
- **Where:** p. 270 (App C, "Bootstrapping Issues")
- **Insight:** Self-reference splits into *bootstrapping* (getting the system up — creating initial classes/gfs "before they can be created") and *metastability* (keeping it running — self-referential calls that recur as it operates). Different cures; treat separately.
- **Why it matters for KEC Lisp:** KEC has exactly this split: a *bootstrap* concern (Core `.lsp` must load in dependency order `00-def → … → 70-sort`; the arena must load Core or fail cleanly) and a *steady-state* concern (Core functions calling each other / the kernel at runtime). Naming them separately is the right model when editing `CORE_SRCS` order or the `kec_open_with_arena` Core-load.
- **Applicability:** Direct

### Ground the recursion in hand-coded base cases
- **Where:** p. 271 (§C.1) and p. 274 (§C.2)
- **Insight:** Closette breaks both regresses by *manufacturing a few base cases by hand* — `standard-class` is created with `allocate-instance` + direct slot-setting rather than the normal `make-instance` path, and `class-of` of the root metaclass is special-cased to terminate the `(class-of (class-of …))` chain. Base cases must be "well-founded" or the loop never bottoms out.
- **Why it matters for KEC Lisp:** KEC's well-founded base is the **frozen Fe kernel + `host/` C primitives** (`cons`, `car`, `set`, `is`/`=`, `type-of` …): they exist before any `.lsp` runs, so Core never defines itself in terms of the not-yet-defined. Treat that C boundary as the recursion-terminating base case — anything a Core module needs *before* the prelude loads must already be a kernel/host primitive, not a Lisp definition.
- **Applicability:** Direct

### A finite, ordered startup sequence makes circularity tractable
- **Where:** p. 270 (§C.1, "there are only a finite number of initial classes and methods")
- **Insight:** Bootstrapping is tractable only because the set of things needed before the machinery exists is *finite and knowable in advance* — the authors enumerate the exact initial classes/methods and build them in a fixed order, so "vicious circles" become a short ordered list rather than an open regress.
- **Why it matters for KEC Lisp:** Validates hardcoding `CORE_SRCS` order in `CMakeLists.txt` rather than auto-resolving dependencies. The load list *is* the enumerated, finite bootstrap sequence; keeping it explicit and ordered is the feature. A new Core module must be slotted at the right position precisely because the order encodes the dependency DAG.
- **Applicability:** Direct

### Self-referential calls need a closed, "real" fallback path
- **Where:** p. 273 (§C.2 "Metastability Issues")
- **Insight:** At steady state, `slot-value` and method lookup would call *themselves* (via `slot-location` → `class-slots` → `slot-value` …). Closette breaks the loop by rewriting the critical-path accessors as **plain closed functions** that don't re-enter the generic machinery, hand-coding the nested chain so it terminates.
- **Why it matters for KEC Lisp:** A cautionary pattern for `core/`: a stdlib function that is *also* used to implement the machinery it sits on must have a non-recursive, closed implementation on the hot/bootstrap path. This is why KEC's list/sequence functions are written **iteratively** — same instinct, applied to GC-stack depth rather than metaobject recursion: keep the foundational path closed and bounded.
- **Applicability:** Analogous

### Push self-definition up; keep the kernel minimal
- **Where:** p. 271 (§C.1) and overall App D structure (most of CLOS is Lisp; only instance/slot access is primitive)
- **Insight:** Closette pushes nearly the *entire* object system into Lisp (precedence lists, slot inheritance, method combination, dispatch — all `defun`s) and keeps only the irreducible substrate primitive: allocating an instance vector and reading/writing a slot by index. Large surface, tiny primitive core.
- **Why it matters for KEC Lisp:** The exact KEC bet — `core/` (Lisp) over `host/` (small portable C) over the frozen Fe VM. Keep the C/`host` surface as thin as the base-case requirement allows and express everything else in Lisp; the FFI seam (`kec_bind_fe`) is where you decide what *must* be primitive vs. self-definable. Resist pulling stdlib logic into C unless the recursion can't be grounded otherwise.
- **Applicability:** Direct

### A complete self-hosted layer can stay strikingly small and readable
- **Where:** App D as a whole (book pp. 277–316), e.g. `std-compute-class-precedence-list` (p. 291), dispatch (pp. 302–303); **skimmed**
- **Insight:** The *entire* working object system — class graph, precedence, slot inheritance, dispatch, method combination — fits in ~40 printed pages of mostly short `defun`s, because each piece is a small Lisp function over plain lists with no premature optimization ("straightforward but very slow," p. 283).
- **Why it matters for KEC Lisp:** Encouragement and a sizing benchmark: KEC's `core/` (11 modules, `00-def`…`70-sort`) being entirely Lisp over a frozen kernel is the *same* architecture that produced a full MOP in ~40 pages. Favor many small, clear Core functions over clever C; clarity of the self-hosted layer is a feature, and "slow but correct first" is an acceptable bootstrap posture.
- **Applicability:** Analogous

### Build-time baking trades live-editability for a single relocatable artifact
- **Where:** pp. 277–278 (App D intro / load `newcl.lisp` then `closette.lisp`)
- **Insight:** Closette ships as source files loaded in a *fixed sequence* (shims first, then the main file) to establish the environment before user code runs — the prelude is a committed, ordered artifact, not discovered dynamically at use-time.
- **Why it matters for KEC Lisp:** Direct parallel to `tools/mkembed.c` baking `core/*.lsp` into C char arrays so the shipped `kec` binary needs no runtime file lookup. The tradeoff Closette accepts (fixed load order, edit-then-reload) is the one KEC accepts: editing a `core/*.lsp` requires a rebuild for the shipped binary — and KEC's `KEC_CORE_DIR` fast path is the dev-time escape hatch Closette lacked. Keep the baked, ordered prelude as the *shipping* contract; the live-layer is convenience only.
- **Applicability:** Direct

### Bootstrap is all-or-nothing → fail cleanly
- **Where:** pp. 270–271 (§C.1, the ordered chain where each step depends on the prior existing)
- **Insight:** The bootstrap is a single ordered chain; a gap anywhere (a base case that isn't actually well-founded) means the system simply cannot come up — there is no partial object system to fall back to.
- **Why it matters for KEC Lisp:** The failure mode behind the no-malloc `kec_open_with_arena`: on the device, if the static arena is too small to load Core, the only safe outcome is "return NULL cleanly" rather than half-initialize. Keep that clean-fail seam well-tested (`tests/c/test_arena.c` / `c/arena`); a wedged prelude on a handheld has no REPL to recover from.
- **Applicability:** Direct

### A no-base-case loop is the symptom to fear most (negative pattern)
- **Where:** p. 269 (App C opening), p. 274 (§C.2)
- **Insight:** The recurring hazard is a self-referential definition with *no* base case — recomputing a gf's discriminating function by *calling* that very gf. The fix is always an explicitly inserted, hand-verified termination point, not cleverness.
- **Why it matters for KEC Lisp:** Guardrail when extending `core/` or the kernel deltas: never let a foundational definition depend, even transitively, on a later-loaded module or on itself through a not-yet-bound symbol. Concretely — don't reorder `CORE_SRCS` casually, and when adding a primitive at the `host`/Lisp boundary, confirm the call graph bottoms out in kernel/host primitives.
- **Applicability:** Avoid

---

## What to ignore (object-system machinery with no KEC analog)

KEC is not getting classes, inheritance, instance slots, generic dispatch, or
method combination. The following are illustrative of the *pattern* (override one
operation, inherit the rest) but their substance does not transfer: class
precedence list ordering rules (Ch 3 pp. 78–82), effective-slot coalescing and
per-instance slot storage (Ch 3 pp. 84–104), the metaobject inheritance lattice
as a thing to *build* (Ch 5 §5.3), and the entire Ch 6 generic-function
dictionary as an API to *implement*. Read them for the meta-pattern only.

---

## Candidate next steps for KEC (derived from these notes)

Concrete, optional, ordered roughly by leverage. None require an object system.

1. **Annotate the FFI surface functional vs procedural.** Add a column/marker in
   `docs/ffi-bridge.md` (and ideally the registration site) tagging each
   `host/host.c` and firmware primitive. Drives caching decisions and the
   SANDBOX/FULL split. *(Lessons #2, #7.)*
2. **Write a one-page "protocol entry" template** (SYNTAX / ARGS / VALUES /
   DEFAULT / OVERRIDE CONTRACT / REMARKS) and apply it to the FFI seam docs, so
   the firmware gets a precise override contract. *(Lesson #9; Ch 5–6.)*
3. **Adopt the Ch 3 §3.9 four-property checklist** (portability, scope control,
   operation control, efficiency) as the review gate for any new seam/profile;
   drop it into `docs/boundary.md`. *(Lesson #8.)*
4. **Classify Core/host symbols safe-to-shadow vs do-not-shadow**, and decide
   whether redefining a load-bearing prelude function (e.g. `map`) should warn.
   *(Lesson #9; Ch 4 §4.2.2.)*
5. **Prototype read-only introspection primitives** — `(bound? sym)`, `(globals
   &opt prefix)`, function arity/param-list, `type-of` already exists — returning
   *fresh, documented-shape* values (fair-use rule), with scope/limit args. Feeds
   a REPL completer and the SYS browser. *(Lessons #5; Ch 2.)*
6. **If/when dispatch or symbol resolution shows up hot on the Pi Zero 2 W,**
   apply the compute-a-plan-then-execute split with an inline cache keyed by a
   stable key, invalidated on global-binding mutation (`set`/top-level `let`).
   *(Lesson #3; Ch 4 §4.4.)*
7. **Audit macros for the "thunk-at-expansion" rule** — any deferred-evaluation
   macro must emit a closure over the call site, not a raw form. *(Ch 5 §5.4.)*

---

*Compiled from a full read of AMOP (Introduction + Chapters 1–5, Chapter 6 skimmed, Appendices C–D; Appendix A CLOS primer, Appendix B exercise solutions, and Appendix E cross-reference were out of scope). Page citations are to the printed book.*
