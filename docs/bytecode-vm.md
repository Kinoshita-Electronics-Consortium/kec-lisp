---
title: Bytecode VM (deferred)
description: Parked design spec for replacing the Fe tree-walking evaluator with an in-process bytecode VM. The tree-walker is retained.
---

**Status:** Deferred (2026-06-14) — parked design. **The tree-walking
interpreter is retained.** This document is kept as the implementation-ready plan
for if/when a revisit trigger fires (§0).
**Scope:** Replace the Fe tree-walking evaluator with a compile-then-run bytecode
virtual machine, in-process, no serialized artifact.
**Relates to:** ADR-0004 (Fe VM selection) — whose title says "Bytecode VM" but
whose selected option (Fe) is a tree-walker. See the ADR-0004 clarification
amendment.

---

## 0. Decision and status (read this first)

**Decision (2026-06-14): keep the tree-walking interpreter. Do not build the
bytecode VM now.** Reason: the current priority is prototyping velocity for a
terminal-based game system on a Raspberry Pi Zero 2 W, and the tree-walker is the
most malleable substrate — new primitive = a `cfunc`; new form = one `switch`
arm; no compiler/VM/GC-rooting surface to keep correct while the language and FFI
are still in flux. On a 1 GHz A53 driving an 80×25 text grid (event-driven
redraw, ~50 ms handler headroom) the interpreter is nowhere near the bottleneck,
and the FFI escape hatch handles any genuinely hot computation (procgen,
pathfinding) by pushing *that one thing* into C — so the whole language never has
to be fast.

### Alternatives considered

| Option | What it is | Verdict |
|---|---|---|
| **Tree-walker (current)** | `eval()` walks the cons-cell AST directly | **Chosen.** Already shipping; maximum malleability; fast enough for a text UI on the Pi. |
| **Analyzing interpreter** (SICP §4.1.7) | Walk the AST once into a tree of pre-classified C thunks; execute that | Deferred. ~2–4× faster by killing re-dispatch, still malleable — but doesn't give proper tail calls / bounded stack / clean per-op sandbox without extra work, and is a *different* representation (throwaway if bytecode is later wanted). The first thing to reach for **only if** profiling shows the interpreter loop itself (not one cfunc-able hot spot) is the wall. |
| **In-memory bytecode VM** (this spec) | Compile AST→bytecode at load, run on a stack VM, no serialized artifact | Deferred to ship-hardening. Gets TCO, bounded stack, precise sandbox; it is the reusable substrate AOT would build on. Heavy correctness investment (compiler + VM + GC rooting) that works against prototyping velocity. |
| **AOT bytecode** | Compile `.lsp`→bytecode on desktop, ship in `.kn86`, device drops the parser | Deferred furthest. Adds a versioned bytecode ABI + verifier (untrusted-cart trust boundary) — a permanent tax. Purely *additive on top of* the in-memory VM, so nothing is lost by deferring it. The "AOT" half of ADR-0004's aspiration. |

Key sequencing insight: in-memory bytecode → AOT is an additive path (shared
compiler + VM); the analyzing interpreter is a *detour* off it. So if bytecode is
ever built, go straight to the in-memory VM in this spec — don't build the
analyzing interpreter first.

### Revisit triggers (make this a data decision, not a vibe)

Reopen this design when **on-device profiling** shows one of:

1. the **interpreter loop itself** — not a single identifiable computation you
   could move into a `cfunc` — is eating the frame budget on the Pi Zero 2 W; or
2. **cart load time** (parsing source on device) becomes a felt delay; or
3. **RAM/footprint** pressure as ship approaches makes dropping the on-device
   parser (AOT) worthwhile; or
4. you need to run **untrusted third-party carts** and want opcode-level
   verification + metering rather than source-level trust.

Until one fires, every hour on the VM is an hour not spent on the game.

---

## 1. Goals and non-goals

### Goals

- **G1 — Replace `eval()` with a bytecode compiler + VM.** Source is read into a
  cons-cell AST exactly as today, then *compiled* to bytecode and *executed* by a
  stack VM. The tree-walker is removed once the conformance suite passes.
- **G2 — Eliminate per-reference environment search.** The current
  `getbound()` ([kernel/fe.c:448](../kernel/fe.c)) walks an association list on
  every variable reference. The compiler resolves every reference to a frame
  slot, an upvalue index, or a global symbol cell. This is the primary speedup.
- **G3 — Proper tail calls.** Tail-position calls reuse the current frame; deep
  tail recursion runs in O(1) VM stack.
- **G4 — Bounded, non-C-stack execution.** Execution depth is a VM-managed
  frame stack, not C recursion. Stack exhaustion becomes a controlled VM error,
  not a host segfault. This removes the reason the desktop build inflates
  `GCSTACKSIZE` to 8192.
- **G5 — Precise sandbox metering.** The GWP-248 instruction budget counts VM
  instructions retired, not `eval()` entries.

### Non-goals (explicitly out, per design decisions)

- **N1 — No serialized/persisted bytecode.** Bytecode is never written to a
  `.kec`/`.kn86` file. `kec build` remains a *source* bundler. Compilation
  happens in-process at load time, on both desktop and device.
- **N2 — No bytecode verifier.** Because bytecode never crosses a trust
  boundary (it is always freshly compiled from source in the same process),
  there is no untrusted-bytecode threat to verify against. The sandbox is the
  instruction budget (G5), not bytecode validation.
- **N3 — No register VM, no JIT, no computed-goto threading in v1.** These are
  noted in §15 as future work.
- **N4 — No new dedicated arithmetic opcodes in v1.** Arithmetic and list
  primitives are ordinary callables (§6). Inlining them into opcodes is a later
  optimization.

### Success criteria

1. The entire `tests/` suite passes under the VM with `eval()` deleted.
2. `examples/*.lsp` produce byte-identical output to the current interpreter.
3. `kec_open_with_arena` still performs **zero `malloc`** (device path intact).
4. Deep tail recursion (e.g. a 1,000,000-iteration tail loop) runs in constant
   VM stack and does not error.

---

## 2. Invariants the design must honor

These come from reading the current kernel; violating any of them is a
correctness or portability regression.

- **I1 — Object model.** A value is an `fe_Object`: two machine words, a
  `union {fe_Object* o; fe_CFunc f; fe_Number n; char c}` for each of `car`/`cdr`,
  type tag in the low bits of `car`. All new runtime objects (code object,
  closure, box) must either fit this 2-word cell or be added to the type enum and
  laid out within it.
- **I2 — GC.** Mark-sweep over a fixed object slab; the only roots are
  `ctx->gcstack[]` and `ctx->symlist`
  ([kernel/fe.c:186](../kernel/fe.c)). Anything the VM holds live — operand
  stack, call frames, in-flight code objects, closures, boxes — **must** be
  reachable from a root or it will be swept mid-run. This is the single largest
  source of risk in this project.
- **I3 — No-malloc arena.** `kec_open_with_arena(buf, size, profile)` takes a
  caller-supplied buffer, never frees it, and must not `malloc`. All compiler
  output and all runtime structures live in that buffer.
- **I4 — KEC semantic deltas (must survive):**
  - assignment is `set`, not `=`;
  - top-level `let` binds **globally** (not a no-op);
  - `GCSTACKSIZE` is compile-time configurable.
- **I5 — Core language semantics (must survive):**
  - `nil` is the only false value and the empty list;
  - numbers are single-precision `float`;
  - `is`/`=` compare numbers by value, strings structurally, and **pairs by
    identity**;
  - quasiquote expands in Core before bytecode compilation sees the resulting
    ordinary forms.
- **I6 — Globals live in the symbol cell.** A global binding is stored in the
  interned symbol's `cdr` (`getbound` falls back to `cdr(sym)`;
  `fe_set` writes `cdr(getbound(sym,&nil))`). Global access is therefore O(1)
  through the interned symbol — the VM keeps this.
- **I7 — Macros expand before execution.** In the tree-walker a macro rewrites
  the call site and re-evaluates ([kernel/fe.c:786](../kernel/fe.c)). In the VM,
  macros are expanded at **compile time** (§7.4).
- **I8 — Embedding API stability.** `fe_eval(ctx, obj)`, `kec_eval_string`, and
  `kec_bind_fe` keep their signatures. `fe_eval` is reimplemented as
  "compile `obj`, then run."

---

## 3. Architecture and pipeline

Compilation granularity is **one top-level form**, interleaved with execution —
exactly as `fe_readfp` + `fe_eval` work today. This is what preserves
define-then-use ordering (including macros defined earlier in a file and used
later).

```
            ┌────────── per top-level form ──────────┐
  source ─► read_() ─► AST ─► macroexpand ─► compile ─► code object ─► vm_run ─► value
   (text)   (unchanged)         (§7.4)        (§7)        (§5,§6)        (§9)
                                   ▲                                       │
                                   └──── compile-time eval of macros ──────┘
                                        (runs macro closures on the VM)
```

- **Reader** — unchanged. Still produces cons-cell ASTs. Required on device.
- **Compiler** (`compile.c`, new) — AST → code object. Pure function of the AST
  plus the live global environment (needed to detect macros, I7).
- **VM** (`vm.c`, new) — executes a code object against a frame stack and an
  operand stack.
- **`eval()`** — deleted at the end of bring-up (§14). `fe_eval` becomes
  `vm_run(compile(ctx, obj))`.

New source files: `kernel/compile.c`, `kernel/vm.c`, `kernel/vm.h`. The
opcode enum and code-object layout live in `vm.h`. (Final file placement is an
implementation detail; they may fold into `fe.c` to keep the kernel a single
translation unit — see §16.)

---

## 4. Object model extensions

Three new heap object kinds, all GC-traced (§11). Type tags appended to the enum
in `fe.h` (`FE_TCODE`, `FE_TCLOSURE`, `FE_TBOX`), keeping existing tag values
fixed.

### 4.1 Code object (`FE_TCODE`)

Immutable, produced by the compiler, shared by all closures over it. Holds:

| Field | Meaning |
|---|---|
| `code` | the bytecode (encoding decided in §12 / open decision **D1**) |
| `consts` | constant pool — quoted data, literals, global symbols referenced |
| `nparams` | declared parameter count |
| `variadic` | whether the last param collects rest args (Fe dotted-tail params) |
| `nslots` | number of local slots the frame needs (params + `let`-locals) |
| `maxstack` | max operand-stack depth (computed by compiler; bounds the frame) |
| `upvals` | upvalue capture descriptors (see §8) |
| `children` | child code objects (for nested `fn`s), so GC reaches them |

Because `nslots` and `maxstack` are known at compile time, the VM can carve an
exactly-sized frame with no per-call growth checks.

### 4.2 Closure (`FE_TCLOSURE`)

A code object plus captured upvalues: `(code . upvalue-vector)`. This is the
runtime callable that `fn` produces. Replaces `FE_TFUNC`. A closure that
captures nothing still carries an empty upvalue vector.

A **macro** is a closure with a macro flag set (replaces `FE_TMACRO`). It is
never called at runtime; the compiler invokes it at compile time (§7.4).

### 4.3 Box (`FE_TBOX`)

A one-slot mutable cell used for a local variable that is **captured by an inner
closure** (§8). Reads and writes of such a variable indirect through the box so
that the closure and the enclosing frame share one mutable location — preserving
Fe's "closures share the binding" semantics (I5/I6).

---

## 5. Instruction set (v1)

Stack machine. Minimal but complete; optimization opcodes deferred (N4, §15).

### Stack / constants
| Opcode | Operands | Effect |
|---|---|---|
| `CONST` | k | push `consts[k]` |
| `NIL` | — | push `nil` |
| `POP` | — | pop and discard |

### Variables
| Opcode | Operands | Effect |
|---|---|---|
| `GETLOCAL` | slot | push frame slot |
| `SETLOCAL` | slot | store top → frame slot (leaves value on stack) |
| `GETLOCALBOX` | slot | push contents of the box in `slot` |
| `SETLOCALBOX` | slot | store top → box in `slot` |
| `GETUPVAL` | i | push contents of upvalue box `i` |
| `SETUPVAL` | i | store top → upvalue box `i` |
| `GETGLOBAL` | k | push `cdr` of the symbol `consts[k]` (I6) |
| `SETGLOBAL` | k | store top → global cell of symbol `consts[k]` |

### Control flow
| Opcode | Operands | Effect |
|---|---|---|
| `JMP` | off | unconditional jump |
| `JMPIFNIL` | off | pop; if `nil`, jump (used by `if`, `while`) |
| `ANDJMP` | off | if top is `nil`, jump (keep value); else pop (short-circuit `and`) |
| `ORJMP` | off | if top is non-`nil`, jump (keep value); else pop (short-circuit `or`) |

### Functions
| Opcode | Operands | Effect |
|---|---|---|
| `CLOSURE` | k, captures… | build a closure from code object `consts[k]` + capture list (§8) |
| `CALL` | n | call value below `n` args with those args (§9.2) |
| `TAILCALL` | n | tail-call: reuse the current frame (§10) |
| `RET` | — | pop frame; caller resumes with the returned value |
| `BOX` | slot | wrap the current value of `slot` in a fresh box, store box back in `slot` |

`BOX` is emitted in a function prologue for each parameter/local that capture
analysis (§8) marks as captured, before any inner `CLOSURE` references it.

---

## 6. Special forms vs. callables

The compiler recognizes exactly the Fe special forms **syntactically**, by head
symbol:

```
let  set  if  fn  mac  while  quote  and  or  do
```

Everything else callable is a **first-class value** invoked via `CALL`:

- the strict kernel primitives (`cons car cdr setcar setcdr list not is atom
  print < <= + - * /`), and
- all host/firmware `fe_cfunc`s (`type-of`, math, string, I/O, and later the
  device API).

To unify the call path, the strict kernel primitives are **reimplemented as
`fe_cfunc`s** (each takes an evaluated argument list, as cfuncs already do). The
old `FE_TPRIM` runtime type and the giant `prim()` switch in `eval()` are
removed. Result: the VM's `CALL` has exactly two callee kinds — **closure** or
**cfunc** (§9.2).

### One intentional, documented divergence

In the tree-walker, special-form names are ordinary `FE_TPRIM` *values* and can
in principle be rebound (`(set x if)`). In the VM they are **syntax**, resolved
at compile time, and cannot be used first-class. This matches essentially every
compiled Lisp and is a deliberate refinement. First-class *functions/primitives*
(`+`, `cons`, `car`, …) remain values and pass through higher-order functions
normally — Core's HOFs are unaffected. This is the **only** intended semantic
change; everything in I4/I5 is preserved.

---

## 7. The compiler

A recursive walk over the (macroexpanded) AST that **emits** instead of
**evaluates**. It carries a compile-time scope describing where each name lives.

### 7.1 Compile-time scope

Per function being compiled:
- a list of local slot names (params first, then `let`-locals in order);
- a reference to the enclosing function's scope (for free-variable resolution);
- the accumulating upvalue descriptor list.

**Name resolution order** for a symbol reference:
1. **local** in the current function → `GETLOCAL`/`GETLOCALBOX` (boxed if captured);
2. **free** — bound in some enclosing function → register an upvalue, emit
   `GETUPVAL` (§8);
3. **global** → `GETGLOBAL` of the interned symbol (I6). No search.

### 7.2 Lowering each special form

- **`quote`** → `CONST k` where `consts[k]` is the quoted datum.
- **`do`** (and any body) → compile each form; `POP` between them; the last
  form's value is the body's value.
- **`if`** — Fe's `if` is multi-armed: `(if c1 e1 c2 e2 … [else])`
  ([kernel/fe.c:673](../kernel/fe.c)). Lower as a `cond`-style chain of
  `JMPIFNIL`/`JMP`. An odd trailing arm is the else; a missing else yields `NIL`.
- **`and` / `or`** → short-circuit chains using `ANDJMP`/`ORJMP`; the surviving
  operand is the result (Fe returns the value, not a boolean).
- **`while`** → `Ltop: <cond>; JMPIFNIL Lend; <body>; POP; JMP Ltop; Lend: NIL`.
  `while` evaluates to `nil`.
- **`set`** → compile the value, then `SETLOCAL(BOX)`/`SETUPVAL`/`SETGLOBAL`
  per resolution of the target symbol.
- **`let`** — *inside a function body*: allocate the next frame slot, compile the
  value, `SETLOCAL`; subsequent references resolve to that slot. *At top level*:
  compile to `SETGLOBAL` (preserves I4 — top-level `let` binds globally).
- **`fn`** → compile the body as a **child code object**, run capture analysis
  (§8), append the child to `consts`, emit `CLOSURE k, captures…`.
- **`mac`** → like `fn`, but the resulting closure is flagged as a macro and
  bound (typically via the surrounding `set`/`define`) into the global
  environment so later forms can expand against it.

### 7.3 Tail-position analysis

A boolean "tail?" flag threads through compilation. A form is in tail position
if its value is the function's result: the last form of a body, both result arms
of a tail `if`, the surviving arm of a tail `and`/`or`. A **call** in tail
position emits `TAILCALL` instead of `CALL` (§10). Everything else is
non-tail.

### 7.4 Macro expansion (compile time)

When the compiler sees `(head . args)` and `head` is a symbol whose **global**
binding is a macro closure, it:
1. runs that closure on the **unevaluated** `args` *on the VM* (compile-time
   execution — macros only use `list`/`cons`/`append`, which are cfuncs);
2. replaces the form with the returned expansion;
3. re-runs the compiler on the expansion (expansions may themselves be macros).

Because compilation is per-top-level-form and interleaved with execution (§3), a
macro defined by an earlier form is present in the global env by the time a later
form uses it.

---

## 8. Closures and variable capture

A local is **captured** if any nested `fn` references it. Capture is determined
at compile time by the child compiler reporting free variables back to the
parent.

**Model: box-on-capture.** A captured local is stored as a `FE_TBOX` (§4.3). The
enclosing frame accesses it via `GETLOCALBOX`/`SETLOCALBOX`; the inner closure
captures *the box itself* as an upvalue and accesses it via
`GETUPVAL`/`SETUPVAL`. Both therefore read and write one shared cell — exactly
the tree-walker's "closures share the binding" behavior (I5/I6), including the
case where the inner closure `set`s a variable the outer one later reads.

Non-captured locals stay as flat slots (`GETLOCAL`/`SETLOCAL`) with no
indirection — the common, fast case.

A `CLOSURE` instruction's capture descriptors each say where the upvalue comes
from: a **local box** of the enclosing frame, or an **upvalue** of the enclosing
closure (for capture through more than one level). At closure-creation the VM
copies those box references into the new closure's upvalue vector.

> **Why not Lua-style open/closed upvalues?** They avoid boxing non-escaping
> locals but require the VM to track open upvalues pointing into the live operand
> stack and "close" them on scope exit — more machinery and more GC subtlety
> (I2). Box-on-capture is simpler and obviously correct on Fe's arena; the extra
> allocation is only for variables that are actually captured. Revisit if
> profiling shows capture-heavy hot paths (§15).

---

## 9. The VM

### 9.1 State (added to `fe_Context`, or a sub-struct it owns)

- **operand stack** — `fe_Object*` array; `sp`.
- **frame stack** — array of frames; `fp`. A frame is
  `{ closure, ip, base }` where `base` is the operand-stack index of the frame's
  slot 0.
- Both live in the arena (I3) and are GC roots (§11).

Stack sizes: bounded by the sum of code objects' `maxstack`/`nslots` along the
active call chain. Overflow raises a controlled `fe_error("stack overflow")`,
never a host crash (G4).

### 9.2 Calling convention

`CALL n`: the callee sits at `stack[sp-n-1]`, its `n` args above it.
- **closure callee** — push a frame: `base = sp-n`, args occupy slots
  `0..n-1`; if `variadic`, surplus args are consed into a list in the last slot;
  too few args is an error (matches `fe_nextarg`). Zero the remaining locals to
  `nil`. Jump into the code object at `ip = 0`.
- **cfunc callee** — collect the `n` args into a Fe list (as the tree-walker's
  `evallist` does), call `cfunc(ctx, args)`, pop callee+args, push the result.
  This is the seam the firmware's device primitives ride on (`kec_bind_fe`),
  unchanged.

`RET`: take the top of the operand stack as the result, pop the frame
(`sp = base`), push the result onto the caller's stack, resume at the caller's
`ip`. Returning from the outermost frame ends `vm_run`.

### 9.3 Dispatch

A single `for (;;) switch (next_op())` loop. Portable C; no computed goto in v1
(N3). The GWP-248 counter increments once per instruction retired (§13).

---

## 10. Tail calls

`TAILCALL n` is `CALL n` that **reuses the current frame** instead of pushing a
new one: move the callee's `n` args down over the current frame's slots, set
`base`/`ip` for the callee, and continue — no frame-stack growth. A cfunc
tail-call is just "call cfunc, then `RET` its result." This gives proper TCO
(G3): unbounded tail recursion in O(1) frame stack.

---

## 11. GC integration (the high-risk section)

`fe_mark` and `collectgarbage` must learn the new object kinds, and the VM's
working memory must be rooted.

- **New roots.** `collectgarbage` ([kernel/fe.c:186](../kernel/fe.c)) marks
  `gcstack` and `symlist` today; it must additionally mark the **operand stack**
  (`stack[0..sp)`) and each active **frame** (its `closure`).
- **New tracing in `fe_mark`:**
  - `FE_TCODE` → mark `consts` and `children`;
  - `FE_TCLOSURE` → mark its code object and every upvalue box;
  - `FE_TBOX` → mark its contents.
- **Compile-time safety.** Intermediate compiler structures (the code object
  under construction, the growing `consts`) must be protected on `gcstack`
  across any allocation, using the existing `fe_savegc`/`fe_pushgc`/
  `fe_restoregc` discipline — allocation can trigger a collection at any point
  (`object()` calls `collectgarbage` when the freelist is empty).

A get-this-wrong here produces intermittent, input-dependent corruption. The
test plan (§13) deliberately includes a tiny-arena, GC-stress configuration to
flush these out early.

---

## 12. Bytecode encoding

Variable-length instruction stream: an opcode cell followed by its operand
cells. Operands are integers (slot/const/jump indices), wide enough for real
programs (no 8-bit operand ceilings). Jumps are relative.

The *storage* of that stream is **open decision D1** (§17) — either packed into
Fe objects (no new allocator, GC-managed) or into a contiguous code region carved
from the arena (faster fetch, lifetime-scoped). The instruction *semantics* in
§5 are independent of that choice.

---

## 13. Sandboxing and limits

- **Instruction budget (GWP-248).** `fe_set_instr_budget` / `fe_get_instr_count`
  / `fe_reset_instr_count` keep their signatures and semantics, but the counter
  now ticks **once per VM instruction retired** rather than per `eval()` entry —
  a tighter, more predictable bound for the scripted-mission sandbox. Budget `0`
  still means unlimited.
- **Stack limits.** Operand- and frame-stack overflow raise `fe_error`, giving
  the sandbox a hard ceiling on recursion/expression depth that today can only be
  approximated via `GCSTACKSIZE`.
- **No bytecode verifier** (N2) — bytecode is always locally compiled, never
  ingested from an untrusted source.

---

## 14. Testing and rollout

Full replacement (chosen), executed in phases so the cutover is verified, not a
leap:

1. **Phase 0 — scaffolding.** Add `vm.h`, empty `compile.c`/`vm.c`. No behavior
   change. Keep `eval()` intact.
2. **Phase 1 — VM behind a build flag, `eval()` retained as oracle.** Route
   `fe_eval` through compile+run when `-DKEC_VM=1`. Run the **entire `tests/`
   suite both ways** in CI; results must match. This temporary coexistence is the
   differential oracle full-replacement otherwise gives up.
3. **Phase 2 — feature completeness.** Land special forms, closures/upvalues,
   tail calls, macro expansion, cfunc unification, until the suite is green under
   the VM and `examples/*` output is byte-identical (success criteria §1–2).
4. **Phase 3 — GC stress.** Run the suite under a deliberately tiny arena and a
   "collect on every allocation" debug mode to shake out §11 rooting bugs.
   Add C-level VM tests under `tests/c/` (the `.lsp` suite can't reach frame/stack
   edge cases), alongside the existing `tests/c/test_arena.c`.
5. **Phase 4 — cutover.** Make the VM unconditional, **delete `eval()`**, the
   `FE_TPRIM` machinery, and the `-DKEC_VM` flag. Reconcile `GCSTACKSIZE` (G4 may
   let the desktop drop back toward the device default). Update CHANGELOG and
   ADR-0004.

New conformance to add: a tail-call test (success criterion §4), a
closure-capture-and-mutate test, and a macro-expansion ordering test.

CI (`.github/workflows/ci.yml`) gains the dual-engine run in Phases 1–3 and
reverts to a single run at Phase 4.

---

## 15. Future work (post-v1)

- Dedicated opcodes for hot primitives (`+`, `cons`, `car`, `cdr`) with a
  guard that the global is unshadowed (N4).
- Computed-goto / direct-threaded dispatch on GCC/Clang, `switch` fallback (N3).
- Contiguous flat-buffer bytecode if D1 chose the Fe-object representation and
  profiling shows fetch cost.
- Open/closed upvalues if capture-heavy code shows boxing overhead (§8).
- Optional AOT serialization (the deferred half of ADR-0004) — would reintroduce
  a container format and a verifier (N1/N2).

---

## 16. Build / file layout

- New: `kernel/vm.h`, `kernel/vm.c`, `kernel/compile.c` — or folded into
  `fe.c` to preserve the single-translation-unit kernel. **Open decision D2.**
- `CMakeLists.txt`: add the new sources to the `kec_core` library; add the
  dual-engine test pass for Phases 1–3.
- No change to `core/`, the embed pipeline (`tools/mkembed.c`), or `kec build`.
- `runtime/kec.c`: on error recovery (`longjmp`), reset the VM operand/frame
  stack pointers, just as it currently relies on `fe_restoregc`.

---

## 17. Open decisions (need a call before/while implementing)

- **D1 — Bytecode storage.**
  - *(A) Fe-object-backed:* bytecode packed into an `FE_TSTRING`-like byte
    vector, constants as a Fe vector; the code object is pure `fe_Object`s. No
    new allocator, GC-managed for free, fully arena/no-malloc clean (I2/I3).
    Slower instruction fetch (linked 7-byte string cells).
  - *(B) Contiguous code region:* split the caller arena into the object slab
    plus a bump region for raw bytecode/const arrays, reset at cart-load/unload
    boundaries (matches ADR-0004's arena-reset discipline). Fast flat fetch; the
    region is lifetime-scoped, not individually GC'd; needs the reset-boundary
    contract wired into the firmware's cart lifecycle.
  - *Recommendation:* start with **(A)** for correctness and a clean device
    story; move to **(B)** only if profiling demands it.
- **D2 — File structure.** Separate `compile.c`/`vm.c` (clearer) vs. fold into
  `fe.c` (keeps the kernel one TU, simplifies the vendored-as-a-library story).
- **D3 — `FE_TPRIM` removal vs. retention.** This spec removes it (cfunc
  unification, §6). The lower-churn alternative keeps `FE_TPRIM` and adds a
  prim-apply path in `CALL`. Removal is cleaner for a full replacement; flagging
  it because it touches kernel internals.
