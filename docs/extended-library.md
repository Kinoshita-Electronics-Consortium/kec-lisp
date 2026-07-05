---
title: Extended Library Reference
description: The editor/REPL tier (editor/*.lsp) — the knEmacs text buffer, structural zipper, keymap engine, completion ranker, REPL engine, and the SEAM contract a host implements. Full per-function reference.
---

Above [Core](/kec-lisp/core-library/) sits a second Lisp library:
`editor/*.lsp`, the **host-agnostic editor/REPL tier** ([ADR-0002](/kec-lisp/adr/adr-0002-editor-repl-extended-library-tier/)).
It's the engine behind [knEmacs](/kec-lisp/knemacs/) and the `kec repl` prompt —
a text buffer, a structural s-expression zipper, undo, a keymap-as-data
dispatcher, a completion ranker, and a REPL loop — all in portable KEC Lisp,
with only device concerns (physical keys, display, persistence backing) left to
the host.

Unlike Core, this tier is **not loaded into every context**. It's
`provide`-gated: a session opts in by loading the modules it needs (the `kec`
CLI does this for `kec nemacs` / `kec repl`; a device host loads them the same
way). Every example on this page shows the `(load ...)` prelude it needs, and
every one was run for real against `./build/kec` — nothing here is guessed.

## The three layers within the tier

The module number prefix encodes load order and layering:

| Modules | Layer | What |
|---|---|---|
| `10`–`40` | **Buffers & data model** | the structural zipper (`10`), the O(1) undo ring (`20`), the structural buffer record (`30`), the line-based **text** buffer (`32`, the real knEmacs buffer), and the abstract view model (`40`). |
| `50`–`72` | **Dispatch & session** | the keymap engine (`50`), major modes (`52`), the default key bindings as data (`55`), serialize/load (`60`), the lifecycle state machine (`70`), and the idle-timer registry (`72`). |
| `80`–`96` | **REPL & host** | the completion ranker (`80`), the `M-x` minibuffer (`85`), the REPL engine (`90`), the structural prompt (`92`), the reference host + SEAM wiring (`95`), and the ANSI TTY painter (`96`). |

## Two buffer models

There are **two** buffer implementations here, and they are not the same thing:

- **`32-text.lsp`** is the real knEmacs file-editing buffer — a *line zipper*
  (lines of characters with a point), the representation you edit when you run
  `kec nemacs`. Structure (paren-matching, sexp motion) is a lens computed on
  top, never the buffer itself.
- **`10-zipper.lsp` + `30-buffer.lsp`** are the older *structural* s-expression
  zipper — every node is a cons cell, every edit returns a new immutable
  location. This still backs the `kec repl` structural prompt (`92-prompt.lsp`)
  and the view model (`40-view.lsp`), and is intended to return as a *lens* over
  the text buffer.

## The SEAM — what a new host implements

ADR-0002 defines the **SEAM** as the set of capabilities LIB requires *from* any
host, stated with no device vocabulary (S1 eval context, S2 input events, S4
render sink, S5 persistence bytes, S6 lifecycle hooks, S8 vocabulary feed, …).
`95-host.lsp` is the reference wiring of that seam to a laptop REPL — the file a
firmware engineer reads to know exactly what to supply. See its section below.

### `editor/10-zipper.lsp` — the s-expression structural zipper (Huet-style), the original knEmacs data model

A buffer is a sequence of top-level forms; the cursor is a *location* `(focus . crumbs)` where `focus` is the subtree under the cursor and `crumbs` is a stack of `(left . right)` frames recording the path back to the root (`left` reversed). Every move or edit returns a **new** location — nothing is mutated — so the tree is always well-formed and undo is an O(1) snapshot of the old location value. All spine traversal is iterative (`while` + index), never recursive, so a deep tree can't exhaust the GC root stack. Boundary moves (descend into a leaf, sibling past an end, ascend past root) `raise` an `"invalid move: ..."` error.

Load with `(load "editor/10-zipper.lsp")`; it registers `'editor/zipper` via `provide`.

**Note:** `at-root?` is **not** true for a location seated on a top-level form — the constructor (`buffer-from-forms`) always seats the cursor with one synthetic frame in place (marking "top level"), so `(at-root? (buffer-from-forms ...))` returns `nil`. It only becomes `t` after ascending past that frame, landing on the flat forms list itself. Don't use `at-root?` to mean "cursor is on a top-level form" — use it to mean "cursor is on the whole-buffer forms list."

#### `(loc-focus loc)`

Returns the subtree currently under the cursor.

- **Parameters:** loc — a location, `(focus . crumbs)`
- **Returns:** the focus value (an atom or a list)

```lisp
(loc-focus (buffer-from-forms (read-all "(a b) (c d)")))  ; => (a b)
```

#### `(loc-crumbs loc)`

Returns the crumb stack — the frames recording the path back up to the root.

- **Parameters:** loc — a location
- **Returns:** a list of frames, innermost first

```lisp
(loc-crumbs (buffer-from-forms (read-all "(a b) (c d)")))  ; => ((nil (c d)))
```

#### `(make-loc focus crumbs)`

Constructs a location from a focus and a crumb stack.

- **Parameters:** focus — the subtree to seat the cursor on; crumbs — the frame stack
- **Returns:** a new location `(focus . crumbs)`

```lisp
(loc-focus (make-loc 'x nil))  ; => x
```

#### `(frame-left f)`

Returns a frame's left-sibling list (stored reversed — nearest sibling first).

- **Parameters:** f — a frame, `(left . right)`
- **Returns:** the reversed left-siblings list

```lisp
(frame-left (make-frame '(x y) '(p q)))  ; => (x y)
```

#### `(frame-right f)`

Returns a frame's right-sibling list, in order.

- **Parameters:** f — a frame
- **Returns:** the right-siblings list

```lisp
(frame-right (make-frame '(x y) '(p q)))  ; => (p q)
```

#### `(make-frame left right)`

Constructs a crumb frame from a reversed left-sibling list and an in-order right-sibling list.

- **Parameters:** left — reversed left siblings; right — right siblings in order
- **Returns:** a frame `(left . right)`

```lisp
(frame-left (make-frame '(x y) '(p q)))  ; => (x y)
```

#### `(at-root? loc)`

True when the location has no crumbs — the focus is the whole flat top-level forms list.

- **Parameters:** loc — a location
- **Returns:** `t` or `nil`

```lisp
(at-root? (ascend (buffer-from-forms (read-all "(a b) (c d)"))))  ; => t
```

#### `(branch? x)`

True when `x` is a pair (a non-atom, descendable node). `nil` (the empty list) is a leaf, not a branch.

- **Parameters:** x — any value
- **Returns:** `t` or `nil`

```lisp
(branch? '(1 2))  ; => t
(branch? 5)        ; => nil
```

#### `(buffer-from-forms forms)`

Builds the initial cursor location for a flat list of top-level forms, seating the cursor on the first form (or on an empty-buffer `nil` focus if `forms` is `nil`).

- **Parameters:** forms — a list of s-expressions (e.g. from `read-all`)
- **Returns:** a location seated on `(car forms)`, with the rest as right siblings

```lisp
(loc-focus (buffer-from-forms (read-all "(a b) (c d)")))  ; => (a b)
```

#### `(loc->forms loc)`

Ascends fully back to the root and returns the whole buffer as a flat list of top-level forms — the round-trip inverse of `buffer-from-forms`.

- **Parameters:** loc — any location in the tree
- **Returns:** the flat top-level forms list

```lisp
(loc->forms (buffer-from-forms (read-all "(a b) (c d)")))  ; => ((a b) (c d))
```

#### `(zip-up loc)`

Reconstructs the parent node from the current frame and pops one crumb level — the core rebuild step other verbs are built from. Raises `"invalid move: ascend past root"` at the true root.

- **Parameters:** loc — a location with at least one crumb
- **Returns:** the location seated on the reconstructed parent

```lisp
(loc-focus (zip-up (descend (buffer-from-forms (read-all "(a b c)")))))  ; => (a b c)
```

#### `(descend loc)`

Moves into the first child of the focus. Raises `"invalid move: descend into leaf"` if the focus isn't a non-empty list.

- **Parameters:** loc — a location whose focus is a branch
- **Returns:** a location seated on the first child

```lisp
(loc-focus (descend (buffer-from-forms (read-all "(a b c)"))))  ; => a
```

#### `(next-sibling loc)`

Moves to the sibling immediately to the right. Raises `"invalid move: next-sibling past last"` at the last sibling, or `"invalid move: next-sibling at root"` at the true root.

- **Parameters:** loc — a location with a right sibling
- **Returns:** a location seated on that sibling

```lisp
(let z (descend (buffer-from-forms (read-all "(a b c)"))))
(loc-focus (next-sibling z))  ; => b
```

#### `(prev-sibling loc)`

Moves to the sibling immediately to the left. Raises `"invalid move: prev-sibling past first"` at the first sibling, or `"invalid move: prev-sibling at root"` at the true root.

- **Parameters:** loc — a location with a left sibling
- **Returns:** a location seated on that sibling

```lisp
(let z (descend (buffer-from-forms (read-all "(a b c)"))))
(set z (next-sibling z))
(loc-focus (prev-sibling z))  ; => a
```

#### `(ascend loc)`

Moves up to the parent, seating focus on the reconstructed parent node. Raises `"invalid move: ascend at root"` at the true root.

- **Parameters:** loc — a location with at least one crumb
- **Returns:** the parent location

```lisp
(loc-focus (ascend (descend (buffer-from-forms (read-all "(a b c)")))))  ; => (a b c)
```

#### `(descend-to-leaf loc)`

Descends repeatedly into the first child until focus is an atom (or an empty list). The route to the leftmost-deepest leaf.

- **Parameters:** loc — any location
- **Returns:** a location seated on the leftmost leaf beneath it

```lisp
(loc-focus (descend-to-leaf (buffer-from-forms (read-all "((a b) c)"))))  ; => a
```

#### `(descend-to-last loc)`

Descends repeatedly into the *last* child at each level — the mirror of `descend-to-leaf`. Used to find the rendered line directly above a node (feeds `line-prev`).

- **Parameters:** loc — any location
- **Returns:** a location seated on the rightmost-deepest leaf beneath it

```lisp
(loc-focus (descend-to-last (buffer-from-forms (read-all "(a (b c))"))))  ; => c
```

#### `(line-next loc)`

Moves by rendered line — the pre-order DFS successor over the tree (Emacs `C-n` at the structural level: down into the first child, else the next sibling, else the nearest ancestor's next sibling). Raises `"invalid move: end of buffer"` at the last line.

- **Parameters:** loc — any location
- **Returns:** the location one rendered line forward

```lisp
(let z (buffer-from-forms (read-all "(a (b c))")))
(loc-focus (line-next z))                 ; => a
(loc-focus (line-next (line-next z)))     ; => (b c)
```

#### `(line-prev loc)`

The mirror of `line-next` — the pre-order DFS predecessor. Raises `"invalid move: beginning of buffer"` at the first line.

- **Parameters:** loc — any location
- **Returns:** the location one rendered line back

```lisp
(let z (buffer-from-forms (read-all "(a (b c))")))
(let z2 (line-next (line-next z)))   ; focus (b c)
(loc-focus (line-prev z2))            ; => a
```

#### `(replace-focus loc new)`

Swaps the focus subtree for `new`, keeping the same crumbs — the building block other edit verbs use.

- **Parameters:** loc — a location; new — the replacement value
- **Returns:** a location seated on `new`

```lisp
(loc-focus (replace-focus (buffer-from-forms (read-all "(a b)")) 'z))  ; => z
```

#### `(insert-leaf loc x)`

Inserts `x` as a new sibling immediately to the right of focus and moves the cursor onto it. Raises `"invalid move: cannot insert at top-level root via sibling"` at the top-level seat.

- **Parameters:** loc — a location not at the top-level root; x — the value to insert
- **Returns:** a location seated on the newly inserted `x`

```lisp
(let z (descend (buffer-from-forms (read-all "(a b)"))))
(loc-focus (ascend (insert-leaf z 'x)))  ; => (a x b)
```

#### `(delete-node loc)`

Removes the focus from its parent. The cursor lands on the right sibling if any, else the left sibling, else the parent becomes an empty list. Raises `"invalid move: cannot delete root"` at the true root.

- **Parameters:** loc — a location not at the true root
- **Returns:** `(new-loc . cut)` — the resulting location and the removed subtree

```lisp
(let r (delete-node (descend (buffer-from-forms (read-all "(a b c)")))))
(loc-focus (car r))  ; => b
(cdr r)              ; => a
```

#### `(paste loc clip)`

Inserts `clip` as a new sibling immediately to the right of focus and moves onto it — the mirror of `insert-leaf` for a captured clipboard value (atom or list). Raises `"invalid move: cannot paste at top-level root"` at the top-level seat.

- **Parameters:** loc — a location not at the top-level root; clip — the value to paste
- **Returns:** a location seated on the pasted `clip`

```lisp
(let z (descend (buffer-from-forms (read-all "(a b)"))))
(loc-focus (ascend (paste z 'zz)))  ; => (a zz b)
```

#### `(wrap loc)`

Replaces focus with a single-element list containing the old focus, then seats the cursor back on the old focus (now the wrapper's sole child).

- **Parameters:** loc — any location
- **Returns:** a location seated on the (unchanged) old focus, now inside a new wrapper list

```lisp
(let z (descend (buffer-from-forms (read-all "(a b)"))))
(loc-focus (ascend (wrap z)))  ; => (a)
```

#### `(splice loc)`

Focus must be a list; replaces it in its parent by splicing in its children in place. Cursor lands on the first spliced child (or on the right sibling/parent if the list was empty, matching `delete-node`). Raises `"invalid move: splice non-list"` on an atom focus, or `"invalid move: cannot splice top-level root"` at the top-level seat.

- **Parameters:** loc — a location whose focus is a list, not at the top-level root
- **Returns:** a location seated on the first spliced-in child

```lisp
(let z (descend (buffer-from-forms (read-all "((a b) c)"))))
(loc-focus (ascend (splice z)))  ; => (a b c)
```

#### `(transpose loc)`

Swaps focus with its next sibling, keeping the cursor logically on the same value (which now sits one position to the right). Raises `"invalid move: transpose past last"` with no next sibling, or `"invalid move: transpose at root"` at the true root.

- **Parameters:** loc — a location with a next sibling
- **Returns:** a location with focus and its former next sibling swapped

```lisp
(let z (descend (buffer-from-forms (read-all "(a b c)"))))
(loc-focus (ascend (transpose z)))  ; => (b a c)
```

#### `(buffer-wellformed? loc expected-forms)`

Round-trips the whole buffer to printed text and back (`repr` then `read-string`), checking the reparsed structure is `equal?` to the live forms — proof that no malformed/cyclic tree slipped in, since such a tree couldn't print and reparse identically. If `expected-forms` is non-nil, also checks the buffer equals it.

- **Parameters:** loc — any location; expected-forms — a forms list to compare against, or `nil` to skip that check
- **Returns:** `t`/`1`-ish truthy value on success, `nil` on failure

```lisp
(buffer-wellformed? (buffer-from-forms (read-all "(a b c)")) nil)  ; => 1
```

---

### `editor/20-undo.lsp` — a fixed-capacity O(1) snapshot ring, backing structural undo

Because the zipper (`10-zipper.lsp`) makes every edit return a new immutable location, a snapshot is just the old location *value* — no deep copy needed. This ring stores the last `cap` snapshots; push/pop are O(1). It is backed by a 4-slot vector (`[storage head count cap]`) plus an internal storage vector — the O(1) ring the cons-list world lacked (ADR-0003 containers). When full, a push overwrites the oldest snapshot (bounded history, the device discipline). The ring is value-agnostic — the editor pushes zipper locations, but it will hold anything.

Load with `(load "editor/20-undo.lsp")`; registers `'editor/undo`.

#### `(make-undo-ring cap)`

Creates a new, empty ring holding up to `cap` snapshots.

- **Parameters:** cap — capacity (number of snapshots retained)
- **Returns:** a new undo-ring vector

```lisp
(undo-depth (make-undo-ring 3))  ; => 0
```

#### `(undo-depth r)`

Returns how many snapshots are currently live (poppable).

- **Parameters:** r — an undo ring
- **Returns:** a count, `0..cap`

```lisp
(let r (make-undo-ring 3))
(undo-push r 'a) (undo-push r 'b)
(undo-depth r)  ; => 2
```

#### `(undo-empty? r)`

True when there is nothing to undo.

- **Parameters:** r — an undo ring
- **Returns:** `t` or `nil`

```lisp
(undo-empty? (make-undo-ring 3))  ; => t
```

#### `(undo-push r snap)`

Records `snap` as the most-recent snapshot. Once `cap` snapshots are held, the next push silently overwrites the oldest one.

- **Parameters:** r — an undo ring; snap — any value to record
- **Returns:** `r`

```lisp
(let r (make-undo-ring 3))
(undo-push r 'a) (undo-push r 'b) (undo-push r 'c) (undo-push r 'd)  ; 'a is now gone
(undo-pop r)  ; => d
```

#### `(undo-pop r)`

Removes and returns the most-recent snapshot, or `nil` if the ring is empty.

- **Parameters:** r — an undo ring
- **Returns:** the popped snapshot, or `nil`

```lisp
(let r (make-undo-ring 3))
(undo-push r 'a) (undo-push r 'b)
(undo-pop r)  ; => b
(undo-pop r)  ; => a
(undo-pop r)  ; => nil
```

#### `(undo-peek r)`

Returns the most-recent snapshot without removing it, or `nil` if empty.

- **Parameters:** r — an undo ring
- **Returns:** the top snapshot, or `nil`

```lisp
(let r (make-undo-ring 3))
(undo-push r 'a) (undo-push r 'b)
(undo-peek r)   ; => b
(undo-depth r)  ; => 2 (unchanged by peek)
```

**Note:** `undo-push`'s overwrite-oldest behavior is silent — there's no signal that history was truncated. A host displaying "can't undo further" messaging needs to track that itself (or just rely on `undo-depth` reaching 0 after draining, since overwritten entries are simply gone).

---

### `editor/30-buffer.lsp` — the L1 buffer record: zipper cursor + clipboard + modified flag + undo, as verb wrappers

Wraps the bare zipper cursor (`10-zipper.lsp`) with the rest of the L1 buffer state — clipboard, modified flag, buffer name — and an undo ring (`20-undo.lsp`), exposing verb wrappers that thread the clipboard, set the modified flag, and snapshot for undo automatically. Navigation moves the cursor only (no undo, no modified flag); structural edits snapshot the pre-edit location for undo and mark modified. The record itself is a small mutable vector (`[loc clipboard modified? name undo-ring literal-text]`) — one handle per open buffer — even though the cursor value inside it stays an immutable zipper location.

**Load order matters:** this file calls `make-undo-ring` (from `20-undo.lsp`) but does not `load` it itself — a host must `(load "editor/10-zipper.lsp")` and `(load "editor/20-undo.lsp")` *before* `(load "editor/30-buffer.lsp")`, or `make-buffer` fails with a non-callable-value error.

#### `(make-buffer name forms)`

Creates a buffer named `name` over the top-level `forms` (e.g. from `read-all`). Cursor seated on the first form; clipboard empty; not modified; not in literal entry; undo ring capacity is the module constant `BUFFER-UNDO-DEPTH` (64).

- **Parameters:** name — a buffer name string; forms — a list of top-level s-expressions
- **Returns:** a new buffer record

```lisp
(buffer-forms (make-buffer "scratch" (read-all "(a b c)")))  ; => ((a b c))
```

#### `(buffer-loc b)`

Returns the buffer's current cursor location (a raw zipper location).

- **Parameters:** b — a buffer
- **Returns:** the location

```lisp
(loc-focus (buffer-loc (make-buffer "s" (read-all "(a b c)"))))  ; => (a b c)
```

#### `(buffer-clipboard b)`

Returns the buffer's clipboard — the last subtree cut by `buffer-delete!`, or `nil`.

- **Parameters:** b — a buffer
- **Returns:** the clipboard value, or `nil`

```lisp
(buffer-clipboard (make-buffer "s" (read-all "(a b)")))  ; => nil
```

#### `(buffer-modified? b)`

True once a structural edit has happened since creation (or since the flag was otherwise cleared).

- **Parameters:** b — a buffer
- **Returns:** `t` or `nil`

```lisp
(buffer-modified? (make-buffer "s" (read-all "(a b)")))  ; => nil
```

#### `(buffer-name b)`

Returns the buffer's name.

- **Parameters:** b — a buffer
- **Returns:** the name string

```lisp
(buffer-name (make-buffer "scratch" (read-all "(a b)")))  ; => "scratch"
```

#### `(buffer-undo-ring b)`

Returns the buffer's underlying undo ring (see `20-undo.lsp`), for hosts that want to inspect depth directly.

- **Parameters:** b — a buffer
- **Returns:** the undo-ring vector

```lisp
(undo-depth (buffer-undo-ring (make-buffer "s" (read-all "(a b)"))))  ; => 0
```

#### `(buffer-forms b)`

Returns the whole buffer as a flat list of top-level forms (round-trips through `loc->forms`).

- **Parameters:** b — a buffer
- **Returns:** the top-level forms list

```lisp
(buffer-forms (make-buffer "s" (read-all "(a b) (c)")))  ; => ((a b) (c))
```

#### `(buffer-focus b)`

Returns the subtree currently under the cursor.

- **Parameters:** b — a buffer
- **Returns:** the focus value

```lisp
(buffer-focus (make-buffer "s" (read-all "(a b c)")))  ; => (a b c)
```

#### `(buffer-descend! b)`

Moves the cursor into the focus's first child. Navigation only — no undo snapshot, no modified flag. Raises the same `"invalid move: ..."` errors as the underlying `descend`.

- **Parameters:** b — a buffer whose focus is a branch
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b c)")))
(buffer-descend! b)
(buffer-focus b)  ; => a
```

#### `(buffer-next! b)`

Moves the cursor to the next sibling. Navigation only.

- **Parameters:** b — a buffer with a next sibling
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b c)")))
(buffer-descend! b) (buffer-next! b)
(buffer-focus b)  ; => b
```

#### `(buffer-prev! b)`

Moves the cursor to the previous sibling. Navigation only.

- **Parameters:** b — a buffer with a previous sibling
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b c)")))
(buffer-descend! b) (buffer-next! b) (buffer-prev! b)
(buffer-focus b)  ; => a
```

#### `(buffer-ascend! b)`

Moves the cursor up to the parent. Navigation only.

- **Parameters:** b — a buffer not at the true root
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b c)")))
(buffer-descend! b) (buffer-ascend! b)
(buffer-focus b)  ; => (a b c)
```

#### `(buffer-to-leaf! b)`

Moves the cursor to the leftmost-deepest leaf beneath focus. Navigation only.

- **Parameters:** b — a buffer
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "((a b) c)")))
(buffer-to-leaf! b)
(buffer-focus b)  ; => a
```

#### `(buffer-line-next! b)`

Moves the cursor forward by rendered line (Emacs `C-n` at the structural level). Navigation only.

- **Parameters:** b — a buffer
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a (b c))")))
(buffer-line-next! b)
(buffer-focus b)  ; => a
```

#### `(buffer-line-prev! b)`

Moves the cursor back by rendered line (Emacs `C-p`). Navigation only.

- **Parameters:** b — a buffer
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a (b c))")))
(buffer-line-next! b) (buffer-line-next! b) (buffer-line-prev! b)
(buffer-focus b)  ; => a
```

#### `(buffer-insert-leaf! b x)`

Inserts `x` as a sibling to the right of focus and moves onto it. Snapshots the pre-edit location for undo and marks the buffer modified.

- **Parameters:** b — a buffer not at the top-level root; x — the value to insert
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b)")))
(buffer-descend! b) (buffer-insert-leaf! b 'x)
(buffer-forms b)  ; => ((a x b))
```

#### `(buffer-wrap! b)`

Wraps focus in a new single-element list, cursor staying on the (now-nested) old focus. Snapshots + marks modified.

- **Parameters:** b — a buffer
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b)")))
(buffer-descend! b) (buffer-wrap! b)
(buffer-forms b)  ; => (((a) b))
```

#### `(buffer-splice! b)`

Splices focus's children into its parent in place of the list itself. Snapshots + marks modified.

- **Parameters:** b — a buffer whose focus is a list, not at the top-level root
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "((a b) c)")))
(buffer-descend! b) (buffer-splice! b)
(buffer-forms b)  ; => ((a b c))
```

#### `(buffer-transpose! b)`

Swaps focus with its next sibling. Snapshots + marks modified.

- **Parameters:** b — a buffer with a next sibling
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b c)")))
(buffer-descend! b) (buffer-transpose! b)
(buffer-forms b)  ; => ((b a c))
```

#### `(buffer-delete! b)`

Cuts the focus to the buffer's clipboard, snapshots the pre-edit location for undo, and marks modified. The cursor lands per `delete-node`'s rule (right sibling, else left, else the emptied parent).

- **Parameters:** b — a buffer not at the true root
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b c)")))
(buffer-descend! b) (buffer-delete! b)
(buffer-forms b)       ; => ((b c))
(buffer-clipboard b)   ; => a
```

#### `(buffer-paste! b)`

Inserts the clipboard subtree as a sibling to the right of focus. A no-op (returns `b` unchanged) when the clipboard is empty — it does not raise even at a position where `paste` itself would.

- **Parameters:** b — a buffer
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b c)")))
(buffer-descend! b) (buffer-delete! b)     ; clipboard <- a, cursor on b
(buffer-paste! b)
(buffer-forms b)  ; => ((b a c))
```

#### `(buffer-undo! b)`

Restores the most-recent undo snapshot. A no-op when the undo ring is empty. The modified flag is left set even after undo (conservative: the buffer may still differ from its last-saved bytes).

- **Parameters:** b — a buffer
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b c)")))
(buffer-descend! b) (buffer-delete! b)
(buffer-undo! b)
(buffer-forms b)  ; => ((a b c))
```

#### `(buffer-can-undo? b)`

True when the undo ring holds at least one snapshot.

- **Parameters:** b — a buffer
- **Returns:** `t` or `nil`

```lisp
(let b (make-buffer "s" (read-all "(a b c)")))
(buffer-can-undo? b)  ; => nil
(buffer-descend! b) (buffer-delete! b)
(buffer-can-undo? b)  ; => t
```

#### `(buffer-literal-text b)`

Returns the pending literal-entry text, or `nil` if not composing a literal.

- **Parameters:** b — a buffer
- **Returns:** the pending text string, or `nil`

```lisp
(buffer-literal-text (make-buffer "s" (read-all "(a b)")))  ; => nil
```

#### `(buffer-in-literal? b)`

True while the buffer is composing a literal value (between `buffer-enter-literal!` and its commit/cancel).

- **Parameters:** b — a buffer
- **Returns:** `t` or `nil`

```lisp
(let b (make-buffer "s" (read-all "(a b)")))
(buffer-enter-literal! b)
(buffer-in-literal? b)  ; => t
```

#### `(buffer-enter-literal! b)`

Begins composing a literal: sets the pending text to `""`.

- **Parameters:** b — a buffer
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b)")))
(buffer-enter-literal! b)
(buffer-literal-text b)  ; => ""
```

#### `(buffer-literal-push! b s)`

Appends `s` to the pending literal text. A no-op if not currently composing a literal.

- **Parameters:** b — a buffer; s — the character(s) to append
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b)")))
(buffer-enter-literal! b) (buffer-literal-push! b "4") (buffer-literal-push! b "2")
(buffer-literal-text b)  ; => "42"
```

#### `(buffer-literal-backspace! b)`

Drops the last character of the pending literal text.

- **Parameters:** b — a buffer, mid-literal
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b)")))
(buffer-enter-literal! b) (buffer-literal-push! b "42") (buffer-literal-backspace! b)
(buffer-literal-text b)  ; => "4"
```

#### `(buffer-cancel-literal! b)`

Discards the pending literal text and leaves literal-entry mode.

- **Parameters:** b — a buffer, mid-literal
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b)")))
(buffer-enter-literal! b) (buffer-literal-push! b "z") (buffer-cancel-literal! b)
(buffer-in-literal? b)  ; => nil
(buffer-forms b)        ; => ((a b)) — unchanged
```

#### `(buffer-commit-literal! b)`

Reads the pending text as a form (via `read-string`) and inserts it as a new leaf at the cursor, then leaves literal-entry mode. A blank/empty pending text just cancels. On an empty buffer (cursor on the `nil` root focus), the first committed form is seated as the buffer's sole top-level form instead of being inserted as a sibling.

- **Parameters:** b — a buffer, mid-literal
- **Returns:** `b`

```lisp
(let b (make-buffer "s" (read-all "(a b)")))
(buffer-descend! b)
(buffer-enter-literal! b) (buffer-literal-push! b "42") (buffer-commit-literal! b)
(buffer-forms b)  ; => ((a 42 b))
```

#### `(buffer-current-form b)`

Ascends from the cursor to the top-level form containing it — the form `eval-current` (host-supplied `eval`, SEAM S1) should evaluate.

- **Parameters:** b — a buffer
- **Returns:** the enclosing top-level form

```lisp
(let b (make-buffer "s" (read-all "(defn f (a) (+ a 1))")))
(buffer-descend! b) (buffer-next! b) (buffer-next! b) (buffer-descend! b)  ; cursor on `a`
(buffer-current-form b)  ; => (defn f (a) (+ a 1))
```

---

### `editor/32-text.lsp` — the real text buffer: a line zipper (lines above/below point, current line, column)

This is the core data structure the rest of knEmacs is built on. The lesson taken from `rxi/lite` and Emacs: **the buffer IS text** — lines of characters with a point — and structure (paren-matching, sexp motion) is a lens computed *on top*, never the representation itself. The structural zipper (`10-zipper` / `30-buffer`) is not replaced by this file; it still backs the `kec repl` structural prompt and is meant to return later as a lens over this buffer. This module is Core-only — no dependency on the zipper — and loads independently, anywhere after Core.

Representation: a **line zipper**, a 13-slot vector `[above cur below col name modified? scroll goal hscroll undo redo mark kill]`:

| Slot | Name | Role |
|---|---|---|
| 0 | `above` | lines above the cursor line, **reversed** (nearest line first) |
| 1 | `cur` | the current line, a plain string |
| 2 | `below` | lines below the cursor line, in order |
| 3 | `col` | column within `cur`, `0..(string-length cur)` |
| 4 | `name` | buffer name (file path or `"*scratch*"`) |
| 5 | `modified?` | `nil`, or `t` once an edit has happened |
| 6 | `scroll` | top visible line index — owned by the renderer |
| 7 | `goal` | desired column for vertical motion (Emacs goal-column feel: `C-n`/`C-p` aim here and clamp to shorter lines without forgetting it) |
| 8 | `hscroll` | leftmost visible column — owned by the renderer, for long-line panning |
| 9 | `undo` | stack of inverse edit records, head = newest |
| 10 | `redo` | stack of records undone (for redo), cleared by any fresh edit |
| 11 | `mark` | `(row . col)` of the mark, or `nil` |
| 12 | `kill` | the kill ring — list of killed strings, head = most recent |

`point-row` is implicit: `(length above)`. Every keystroke touches only `cur` (a substring/`string-append` splice) or shuffles exactly one line between `above`/`below` — all O(1), all iterative. Undo is **command-based**: an undo record is `(op row col text)` with `op` = `:ins` (insert `text` at `row`/`col`) or `:del` (delete `text`, currently found at `row`/`col`) — the two are inverses of each other, and only the changed span is stored, not a whole-buffer snapshot, so it stays cheap on a large file.

Load with `(load "editor/32-text.lsp")`; registers `'editor/text`.

#### `(text-open name content)`

Creates a text buffer named `name` holding `content` (split on newline via a single O(n) `string-split` pass — the module comment notes an earlier per-index `string-ref` loop was O(n²) and hung on large files). Cursor starts at row 0, col 0; not modified.

- **Parameters:** name — buffer name; content — the initial text (may contain embedded newlines)
- **Returns:** a new text-buffer vector

```lisp
(text->string (text-open "t" "ab\ncd\nef"))  ; => "ab\ncd\nef"
```

#### `(text-above b)`

Returns the lines above the cursor line, reversed (nearest first).

- **Parameters:** b — a text buffer
- **Returns:** a list of line strings

```lisp
(text-above (text-open "t" "ab\ncd\nef"))  ; => nil
```

#### `(text-cur b)`

Returns the current line as a plain string.

- **Parameters:** b — a text buffer
- **Returns:** the current line string

```lisp
(text-cur (text-open "t" "ab\ncd\nef"))  ; => "ab"
```

#### `(text-below b)`

Returns the lines below the cursor line, in order.

- **Parameters:** b — a text buffer
- **Returns:** a list of line strings

```lisp
(text-below (text-open "t" "ab\ncd\nef"))  ; => ("cd" "ef")
```

#### `(text-col b)`

Returns the column within the current line.

- **Parameters:** b — a text buffer
- **Returns:** a column index

```lisp
(text-col (text-open "t" "ab"))  ; => 0
```

#### `(text-name b)`

Returns the buffer's name.

- **Parameters:** b — a text buffer
- **Returns:** the name string

```lisp
(text-name (text-open "t" ""))  ; => "t"
```

#### `(text-modified? b)`

True once an edit has happened.

- **Parameters:** b — a text buffer
- **Returns:** `t` or `nil`

```lisp
(text-modified? (text-open "t" "ab"))  ; => nil
```

#### `(text-scroll b)`

Returns the top visible line index — state the renderer owns and persists via `text-screen`.

- **Parameters:** b — a text buffer
- **Returns:** a line index

```lisp
(text-scroll (text-open "t" "ab"))  ; => 0
```

#### `(text-goal b)`

Returns the goal column for vertical motion.

- **Parameters:** b — a text buffer
- **Returns:** a column index

```lisp
(text-goal (text-open "t" "ab"))  ; => 0
```

#### `(text-hscroll b)`

Returns the leftmost visible column — renderer-owned state for panning across long lines.

- **Parameters:** b — a text buffer
- **Returns:** a column index

```lisp
(text-hscroll (text-open "t" "ab"))  ; => 0
```

#### `(text-point-col b)`

Alias for `text-col` — the point's column.

- **Parameters:** b — a text buffer
- **Returns:** a column index

```lisp
(text-point-col (text-open "t" "ab"))  ; => 0
```

#### `(text-point-row b)`

Returns the point's row — derived as `(length (text-above b))`, not stored directly.

- **Parameters:** b — a text buffer
- **Returns:** a row index

```lisp
(text-point-row (text-open "t" "ab\ncd"))  ; => 0
```

#### `(text-line-count b)`

Returns the total number of lines in the buffer.

- **Parameters:** b — a text buffer
- **Returns:** a count (always ≥ 1)

```lisp
(text-line-count (text-open "t" "ab\ncd\nef"))  ; => 3
```

#### `(text->string b)`

Serializes the whole buffer back to one string, lines joined by `\n`.

- **Parameters:** b — a text buffer
- **Returns:** the buffer's full text

```lisp
(text->string (text-open "t" "ab\ncd\nef"))  ; => "ab\ncd\nef"
```

#### `(text-next-line! b)`

Moves point down one line: shuffles `cur` onto `above` and pulls the first `below` line into `cur`. Column lands at the goal column, clamped to the new line's length (a no-op at the last line).

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "ab\ncd"))
(text-next-line! b)
(text-point-row b)  ; => 1
```

#### `(text-prev-line! b)`

The mirror of `text-next-line!` — moves point up one line (a no-op at the first line).

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "ab\ncd"))
(text-next-line! b) (text-prev-line! b)
(text-point-row b)  ; => 0
```

#### `(text-forward! b)`

Moves point forward one character, wrapping to the start of the next line at end-of-line (a no-op at the very end of the buffer). Every horizontal move re-anchors the goal column to the new position.

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "ab"))
(text-forward! b) (text-col b)  ; => 1
```

#### `(text-backward! b)`

The mirror of `text-forward!` — moves point back one character, wrapping to the end of the previous line at column 0 (a no-op at the very start of the buffer).

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "ab\ncd"))
(text-next-line! b) (text-bol! b) (text-backward! b)
(list (text-point-row b) (text-col b))  ; => (0 2) — end of "ab"
```

#### `(text-bol! b)`

Moves point to the beginning of the current line (column 0).

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "ab"))
(text-eol! b) (text-bol! b)
(text-col b)  ; => 0
```

#### `(text-eol! b)`

Moves point to the end of the current line.

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "ab"))
(text-eol! b)
(text-col b)  ; => 2
```

#### `(text-beg! b)`

Moves point to the very beginning of the buffer (row 0, col 0).

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "ab\ncd\nef"))
(text-beg! b)
(list (text-point-row b) (text-col b))  ; => (0 0)
```

#### `(text-end! b)`

Moves point to the very end of the buffer (last line, last column).

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "ab\ncd\nef"))
(text-end! b)
(list (text-point-row b) (text-col b))  ; => (2 2)
```

**Note:** goal-column tracking is real and verified: moving to column 4 on a long line, then `text-next-line!` onto a 2-character line clamps the visible column to 2 but keeps the *goal* at 4; moving down again to another long line restores column 4 — exactly the Emacs `C-n`/`C-p` "remembers where you were" feel, implemented by never touching the goal slot on a vertical move, only on horizontal ones.

#### `(text-insert! b s)`

Inserts `s` (one line's worth, no embedded newline) at point and records an inverse `:del` undo entry. Consecutive inserts that abut the previous edit's span **coalesce into a single undo step** — so typing a whole word undoes in one `text-undo!` call, not one per keystroke — capped at **20 characters per step** (matching Emacs's `undo-auto-amalgamate` boundary); a longer run splits into successive 20-character undo groups.

- **Parameters:** b — a text buffer; s — text to insert (no newline)
- **Returns:** the raw-insert result (buffer state; return value not meaningful, call for effect)

```lisp
(let b (text-open "t" ""))
(text-insert! b "h") (text-insert! b "i")
(text->string b)  ; => "hi"
(text-undo! b)
(text->string b)  ; => "" (both inserts undo together)
```

#### `(text-newline! b)`

Splits the current line at point, recording the inverse delete.

- **Parameters:** b — a text buffer
- **Returns:** the raw-newline result

```lisp
(let b (text-open "t" "ab"))
(text-eol! b) (text-newline! b)
(text-line-count b)  ; => 2
```

#### `(text-backspace! b)`

Deletes the character before point; at column 0 it joins the current line onto the previous one. A no-op (and records nothing) at the very start of the buffer. Consecutive character deletes around one spot (backspaces, forward deletes, or a mix) **coalesce into a single undo step**, capped at 20 characters like inserts — one `text-undo!` restores the whole run.

- **Parameters:** b — a text buffer
- **Returns:** the raw-backspace result

```lisp
(let b (text-open "t" "ab\ncd"))
(text-next-line! b) (text-bol! b) (text-backspace! b)
(text->string b)  ; => "abcd"
```

#### `(text-delete! b)`

Deletes the character at point (forward delete); at end-of-line it joins the next line onto the current one. A no-op at the very end of the buffer. Coalesces with adjacent character deletes into one undo step (capped at 20 characters), same as `text-backspace!`.

- **Parameters:** b — a text buffer
- **Returns:** the raw-delete result

```lisp
(let b (text-open "t" "ab\ncd"))
(text-eol! b) (text-delete! b)
(text->string b)  ; => "abcd"
```

#### `(text-insert-tab! b)`

Inserts spaces up to the next tab stop (fixed width 2, module constant `%text-tab-width`) — never a literal tab byte. The header comment explains why: a real tab renders as several cells on the fixed display grid, which would desync point from the visible cursor (which counts one column per byte); soft spaces keep them in lockstep.

- **Parameters:** b — a text buffer
- **Returns:** the raw-insert result

```lisp
(let b (text-open "t" ""))
(text-insert-tab! b)
(text-col b)  ; => 2
```

#### `(text-goto! b row col)`

Moves point directly to an absolute `(row, col)`, clamping `col` to the target line's length. Used internally to replay undo/redo records, but is a plain public motion primitive too.

- **Parameters:** b — a text buffer; row — target row; col — target column (clamped)
- **Returns:** `b` (via the final column-set call)

```lisp
(let b (text-open "t" "abc\ndef\nghi"))
(text-goto! b 2 1)
(list (text-point-row b) (text-col b))  ; => (2 1)
```

#### `(text-undo! b)`

Undoes the most recent recorded edit, pushing its inverse onto the redo stack. A no-op when the undo stack is empty.

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" ""))
(text-insert! b "hi")
(text-undo! b)
(text->string b)  ; => ""
```

#### `(text-redo! b)`

Redoes the most recently undone edit, pushing its inverse back onto the undo stack. Because redo replays through the raw (non-recording) ops, redoing does not clear the redo stack itself — only a fresh edit via the public `text-*` wrappers does that.

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" ""))
(text-insert! b "hi") (text-undo! b) (text-redo! b)
(text->string b)  ; => "hi"
```

#### `(text-can-undo? b)`

True when the undo stack is non-empty.

- **Parameters:** b — a text buffer
- **Returns:** `t` or `nil`

```lisp
(let b (text-open "t" ""))
(text-can-undo? b)  ; => nil
(text-insert! b "h")
(text-can-undo? b)  ; => t
```

#### `(text-can-redo? b)`

True when the redo stack is non-empty.

- **Parameters:** b — a text buffer
- **Returns:** `t` or `nil`

```lisp
(let b (text-open "t" ""))
(text-insert! b "h") (text-undo! b)
(text-can-redo? b)  ; => t
```

#### `(text-mark-saved! b)`

Clears the modified flag after the host successfully writes the buffer out (e.g. after `write-file` succeeds) — content is untouched, only slot 5 changes. Lets the modeline drop its `*` and lets a quit guard know there's nothing to lose.

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" ""))
(text-insert! b "x")
(text-mark-saved! b)
(text-modified? b)  ; => nil
```

#### `(text-mark b)`

Returns the mark position `(row . col)`, or `nil` if unset.

- **Parameters:** b — a text buffer
- **Returns:** `(row . col)` or `nil`

```lisp
(text-mark (text-open "t" "abc"))  ; => nil
```

#### `(text-set-mark! b)`

Drops the mark at the current point (Emacs `C-SPC`).

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "hello"))
(text-set-mark! b)
(text-mark b)  ; => (0 . 0)
```

**Note:** the mark is a plain saved position — it is not an adjusting marker. If you edit the buffer above the mark before killing the region, the mark stays where it was numerically and no longer lines up with the original text. The module comment calls this out explicitly: "use it set-then-kill."

#### `(text-kill-region! b)`

Kills the region between the mark and point (`C-w`): pushes the region text onto the kill ring, deletes it as one undo step, and leaves point at the region's start. Deactivates the mark. A no-op without a mark set.

- **Parameters:** b — a text buffer with a mark set
- **Returns:** `b`

```lisp
(let b (text-open "t" "hello world"))
(text-set-mark! b)
(text-forward! b) (text-forward! b) (text-forward! b) (text-forward! b) (text-forward! b)
(text-kill-region! b)
(text->string b)  ; => " world"
```

#### `(text-kill-ring-save! b)`

Copies the mark..point region onto the kill ring without deleting it (`M-w`). Deactivates the mark. A no-op without a mark set.

- **Parameters:** b — a text buffer with a mark set
- **Returns:** `b`

```lisp
(let b (text-open "t" "hello world"))
(text-set-mark! b)
(text-forward! b) (text-forward! b) (text-forward! b) (text-forward! b) (text-forward! b)
(text-kill-ring-save! b)
(text-mark b)  ; => nil (deactivated, buffer text unchanged)
```

#### `(text-kill-line! b)`

Kills from point to the end of the current line (not including the newline) (`C-k`). At end-of-line, kills the newline itself (joining the next line up). A no-op at the very end of the buffer.

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "hello world"))
(text-forward! b) (text-forward! b)
(text-kill-line! b)
(text->string b)  ; => "he"
```

#### `(text-yank! b)`

Inserts the most recent kill-ring entry at point (`C-y`), as a single undo step. Sets the mark at the *start* of the inserted text, leaving point after it — matching Emacs's "point after, mark before" convention. A no-op when the kill ring is empty.

- **Parameters:** b — a text buffer
- **Returns:** `b`

```lisp
(let b (text-open "t" "hello world"))
(text-set-mark! b)
(text-forward! b) (text-forward! b) (text-forward! b) (text-forward! b) (text-forward! b)
(text-kill-ring-save! b)
(text-goto! b 0 11)
(text-yank! b)
(text->string b)  ; => "hello worldhello"
```

#### `(text-search-forward b needle sr sc)`

Finds the first occurrence of the single-line `needle` at or after `(sr, sc)`. Iterates the flattened line list linearly (not `nth`-per-line), so it stays O(lines) rather than O(lines²).

- **Parameters:** b — a text buffer; needle — search text (must not contain a newline); sr, sc — the row/col to start searching from
- **Returns:** `(row . col)` of the first match, or `nil`

```lisp
(text-search-forward (text-open "t" "foo bar\nbaz foo") "foo" 0 1)  ; => (1 . 4)
```

#### `(text-search-move! b needle fr fc)`

Drives the incremental (`C-s`) search loop: finds `needle` at or after `(fr, fc)` and, on a hit, moves point to the match's end while setting the mark at the match's start (so the found text becomes the active region). Returns `nil` and leaves point untouched on a miss or an empty needle.

- **Parameters:** b — a text buffer; needle — search text; fr, fc — row/col to start from
- **Returns:** `t` on a match (with point/mark moved), `nil` on a miss

```lisp
(let b (text-open "t" "foo bar\nbaz foo"))
(text-search-move! b "foo" 0 1)
(list (text-point-row b) (text-col b))  ; => (1 7)
(text-mark b)                            ; => (1 . 4)
```

#### `(text-screen b cols rows status)`

Renders the buffer as an ANSI escape-coded string for a `cols`×`rows` terminal: row 1 is an inverse-video modeline (name, a `*` if modified, `L`/`C` position), the middle rows are the vertically- and horizontally-scrolled visible text window (rows past end-of-buffer stay blank, as in Emacs), the last row is the supplied `status`/echo text, and the string ends with an absolute cursor-park escape so the terminal's hardware cursor lands exactly at point. This call also recomputes and persists `scroll`/`hscroll` (slots 6/8) so point stays on-screen — it is not a pure read.

- **Parameters:** b — a text buffer; cols, rows — terminal dimensions; status — the bottom-row status/echo text
- **Returns:** the full ANSI-coded frame string

```lisp
(text-screen (text-open "*scratch*" "one\ntwo\nthree") 10 5 "READY")
;; => "\x1b[7m *scratch*\x1b[0m\none\ntwo\nthree\nREADY\x1b[2;1H"
;; (the modeline " *scratch*" is exactly 10 chars here, so pad-right adds nothing)
```

---

### `editor/40-view.lsp` — the abstract structural view model (SEAM S4), decoupling render from the zipper buffer

LIB emits an abstract view model; the host paints it. The node shapes here mirror the KN-86 firmware nEmacs screen's own seam (`nemacs/tree`, `/cursor`, `/modeline`, `/echo`, `/signature-for`) so that a device screen implementation can drive this Lisp engine as a drop-in for its C core. A **view node** is `(label . children)` — `label` a display string, `children` a list of child view nodes (`nil` for a leaf) — exactly the `ui/tree` node shape used elsewhere in the KN-86 stack. This module builds on the structural zipper/buffer (`10-zipper`, `30-buffer`), not the text buffer.

Load with `(load "editor/10-zipper.lsp")` then `(load "editor/30-buffer.lsp")` then `(load "editor/40-view.lsp")`; registers `'editor/view`.

#### `(form->view form)`

Converts an s-expression into a view-node tree, recursively. Every node — leaf or list — is labelled by a truncated `repr` of the subtree it represents (a structural preview), so a list node shows what it contains rather than just its head symbol.

- **Parameters:** form — any s-expression
- **Returns:** a view node `(label . children)`

```lisp
(form->view 'x)               ; => ("x")
(form->view (read-string "(a b)"))  ; => ("(a b)" ("a") ("b"))
```

#### `(buffer->view b)`

Builds the whole-buffer view tree: a synthetic root node labelled by the buffer name, whose children are the view nodes for each top-level form, plus the specific node within it that corresponds to the current cursor position (matched by identity, for the host to highlight/select).

- **Parameters:** b — a buffer (from `30-buffer.lsp`)
- **Returns:** `(root . cursor)` — the root view node and the cursor's view node within it

```lisp
(let b (make-buffer "*scratch*" (read-all "(a b) (c)")))
(buffer-descend! b)
(car (buffer->view b))  ; => ("*scratch*" ("(a b)" ("a") ("b")) ("(c)" ("c")))
(cdr (buffer->view b))  ; => ("a")
```

#### `(buffer-modeline b)`

Returns the modeline string: the buffer name, plus `" *"` when modified.

- **Parameters:** b — a buffer
- **Returns:** a modeline string

```lisp
(buffer-modeline (make-buffer "*scratch*" (read-all "(a b)")))  ; => "*scratch*"
```

#### `(buffer-echo b)`

Returns a one-line cursor-context hint for the echo area. While composing a literal (see `buffer-enter-literal!` in `30-buffer.lsp`), shows the pending text with a trailing caret (`_`); otherwise shows the focus's kind (`:list` for a pair, else its `type-of` keyword, e.g. `:symbol`) and its crumb depth.

- **Parameters:** b — a buffer
- **Returns:** the echo string

```lisp
(let b (make-buffer "s" (read-all "(a b)")))
(buffer-descend! b)
(buffer-echo b)  ; => ":symbol @ depth 2"
```

**Note:** the depth reported is the crumb-stack length, which includes the synthetic top-level frame `buffer-from-forms` always seats — so a symbol one level inside a single top-level form reports depth 2, not depth 1 as a naive nesting count might suggest.

#### `(completion-signature token)`

Looks up `token` as a symbol name; if it's bound in the current context to a Lisp function, returns `"token (params)"` using its argument list (via `fn-params`). Returns `nil` for an unbound name or for a C builtin (`fn-params` returns `nil` for those, since they carry no Lisp-level arglist). Lifted from the firmware's `nemacs/signature-for`.

- **Parameters:** token — a symbol name string
- **Returns:** a signature string, or `nil`

```lisp
(defn my-fn (a b) (+ a b))
(completion-signature "my-fn")           ; => "my-fn (a b)"
(completion-signature "car")             ; => nil (C builtin, no arglist)
(completion-signature "no-such-fn-xyz")  ; => nil (unbound)
```

#### `(view-line-depth rec)`

Accessor: the indent depth of a `buffer->view-lines` record.

- **Parameters:** rec — a view-line record `(depth label cursor?)`
- **Returns:** the depth (an integer, 0 at the root)

```lisp
(view-line-depth (list 2 "a" t))  ; => 2
```

#### `(view-line-label rec)`

Accessor: the display label of a `buffer->view-lines` record.

- **Parameters:** rec — a view-line record
- **Returns:** the label string

```lisp
(view-line-label (list 2 "a" t))  ; => "a"
```

#### `(view-line-cursor? rec)`

Accessor: whether a `buffer->view-lines` record is the line under the cursor.

- **Parameters:** rec — a view-line record
- **Returns:** `t` or `nil`

```lisp
(view-line-cursor? (list 2 "a" t))  ; => t
```

#### `(buffer->view-lines b)`

Flattens `buffer->view`'s tree into a pre-order list of `(depth label cursor?)` records — for a host that paints a line-oriented structural view (SEAM S4's "structural spans: indent depth, highlight"). Walks an explicit stack (iterative DFS), so it stays GC-stack-safe on a deep tree.

- **Parameters:** b — a buffer
- **Returns:** a list of view-line records, in pre-order (root first)

```lisp
(let b (make-buffer "s4" (read-all "(a (b c))")))
(buffer-descend! b)  ; cursor on `a`
(buffer->view-lines b)
;; => ((0 "s4" nil)
;;     (1 "(a (b c))" nil)
;;     (2 "a" t)
;;     (2 "(b c)" nil)
;;     (3 "b" nil)
;;     (3 "c" nil))
```

---

### `editor/50-keymap.lsp` — the keymap engine: keymap-as-data, dispatch, and mode scopes (L2/L3)

A keymap maps abstract command tokens (`CAR`, `CDR`, `BACK`, ...) — never physical
scancodes — to handlers. A host maps its own keys to these tokens; dispatch is
pure lookup + call, so the whole module is evaluable headlessly (no display
dependency). An entry is an alist of handler slots (`:tap` / `:double-tap` /
`:long-press`); `:double-tap` and `:long-press` fall back to `:tap` when not
separately bound. A handler takes the editor state (a buffer) and returns the
next state.

Load with (from repo root):

```lisp
(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/50-keymap.lsp")
```

#### `MODE-NEMACS-NAV`, `MODE-NEMACS-LITERAL`, `MODE-REPL-PROMPT`, `MODE-REPL-HISTORY`, `MODE-GRAB`

The five logical mode scopes (L3) as symbol constants, plus `KEYMAP-MODES`, the
list of all five. The cursor position selects the active mode
(context-polymorphic); the host calls dispatch with the resolved mode.

- **Returns:** each is bound to a keyword symbol, e.g. `MODE-NEMACS-NAV` is `':nemacs-nav`.

```lisp
(list MODE-NEMACS-NAV MODE-NEMACS-LITERAL MODE-REPL-PROMPT MODE-REPL-HISTORY MODE-GRAB)
; => (:nemacs-nav :nemacs-literal :repl-prompt :repl-history :grab)
```

#### `*keymap-rebind-hook*`

An optional hook variable, `nil` by default. When set to a function, it fires
as `(hook keymap token)` after every `define-key` call. The library stays
policy-neutral — the device (D2) sets whatever rebind-audit or persistence
policy it wants by assigning this variable.

- **Returns:** `nil` unless assigned.

#### `(make-keymap)`

Create a new, empty keymap. A keymap is a hash table under the hood.

- **Returns:** a fresh keymap (opaque hash table handle).

```lisp
(make-keymap)  ; => a hash table, e.g. [ptr 0xb5efd3340]
```

#### `(define-key km token . rest)`

Bind `token` in keymap `km`. Two call shapes: `(define-key km token handler)`
binds the `:tap` slot; `(define-key km token slot handler)` binds a specific
slot (`:tap`, `:double-tap`, or `:long-press`). Fires `*keymap-rebind-hook*` if
one is set.

- **Parameters:** `km` — a keymap; `token` — the command token to bind; `rest` — either `(handler)` or `(slot handler)`.
- **Returns:** `km`.

```lisp
(let km (make-keymap))
(define-key km 'INC (fn (st) (+ st 1)))
(keymap-dispatch km 'INC ':tap 10)  ; => 11
```

#### `(keymap-get km token)`

Look up the raw entry (the slot alist) bound to `token`.

- **Parameters:** `km` — a keymap; `token` — the command token.
- **Returns:** the entry alist, or `nil` if `token` is unbound.

```lisp
(keymap-get (make-keymap) 'FOO)  ; => nil
```

#### `(keymap-set km token entry)`

Install a whole entry (a slot alist) for `token`, replacing any prior binding.

- **Parameters:** `km` — a keymap; `token` — the command token; `entry` — an alist of `(slot . handler)` pairs.
- **Returns:** `km`.

#### `(keymap-handler km token event-type)`

Resolve the handler for `token` under `event-type`. Non-`:tap` event types fall
back to `:tap` when no handler is bound for that specific slot.

- **Parameters:** `km` — a keymap; `token` — the command token; `event-type` — one of `:tap`, `:double-tap`, `:long-press`.
- **Returns:** the handler function, or `nil` if unresolved.

```lisp
(let km (make-keymap))
(define-key km 'X ':long-press (fn (st) st))
(keymap-handler km 'X ':tap)         ; => nil  (no :tap, and no fallback target since :tap itself is what's missing)
(keymap-handler km 'X ':long-press)  ; => the bound function
```

**Note:** the fallback direction is one-way — a `:long-press`-only binding does
**not** answer a `:tap` query. Only `:double-tap`/`:long-press` queries fall
back to `:tap`, never the reverse.

#### `(copy-keymap km)`

Shallow-copy a keymap: a new hash table with the same token→entry pairs
(entries themselves are shared, not deep-copied).

- **Parameters:** `km` — the keymap to copy.
- **Returns:** a new, independent keymap.

```lisp
(let km (make-keymap))
(define-key km 'A (fn (st) 'orig))
(let km2 (copy-keymap km))
(define-key km2 'A (fn (st) 'changed))
(keymap-dispatch km 'A ':tap nil)   ; => orig
(keymap-dispatch km2 'A ':tap nil)  ; => changed
```

#### `(keymap-dispatch km token event-type st)`

Resolve and call the handler for `token`/`event-type`, passing it `st`. An
unbound token (or an unfilled slot with no `:tap` fallback) is a no-op:
returns `st` unchanged.

- **Parameters:** `km` — a keymap; `token` — the command token; `event-type` — `:tap`/`:double-tap`/`:long-press`; `st` — the state to pass to the handler.
- **Returns:** the handler's result, or `st` if nothing resolved.

```lisp
(keymap-dispatch (make-keymap) 'NOPE ':tap 7)  ; => 7
```

#### `(register-keymap mode km)`

Register `km` as the keymap for mode scope `mode` in the global mode registry
(`*keymaps*`).

- **Parameters:** `mode` — a mode-scope keyword; `km` — the keymap.
- **Returns:** `km`.

#### `(keymap-mode mode)`

Look up the keymap registered for `mode`.

- **Parameters:** `mode` — a mode-scope keyword.
- **Returns:** the keymap, or `nil` if unregistered.

#### `(keymap-mode-list)`

- **Returns:** the list of all registered mode scopes (keys of `*keymaps*`).

#### `(mode-dispatch mode token event-type st)`

Like `keymap-dispatch`, but looks the keymap up by mode scope first. An
unregistered mode is a no-op.

- **Parameters:** `mode` — a mode-scope keyword; `token`, `event-type`, `st` — as in `keymap-dispatch`.
- **Returns:** the next state, or `st` unchanged if the mode or token is unbound.

```lisp
(defn mkbuf (name s) (make-buffer name (read-all s)))
(let b (mkbuf "s" "(a b c)"))
(mode-dispatch MODE-NEMACS-NAV 'CAR ':tap b)  ; descend
(buffer-focus b)  ; => a
```

#### `*nemacs-nav-keymap*`

The default `:nemacs-nav` keymap (the ADR-0008 structural grammar), already
registered under `MODE-NEMACS-NAV`. Binds `CAR` (descend), `CDR` (next
sibling; `:long-press` deletes), `BACK` (ascend), `QUOTE` (previous sibling),
`ATOM` (jump to leaf), `CONS` (wrap), `LINK` (splice). `CONS`/`ENT`/`EVAL` get
further bindings from the ranker/REPL workstreams onto this same mutable
keymap.

```lisp
(let b (mkbuf "s" "(a b)"))
(mode-dispatch MODE-NEMACS-NAV 'CAR ':tap b)   ; on 'a (a leaf)
(mode-dispatch MODE-NEMACS-NAV 'CAR ':tap b)   ; descend into a leaf -> raises
; => error: invalid move (propagates to the host, SEAM S7 — dispatch does not
;    swallow boundary-move errors)
```

---

### `editor/52-mode.lsp` — general major modes: the application-engine bundle over the keymap engine

Where `50-keymap` is the keymap *engine*, this module bundles a keymap with the
rest of a mode's class-level identity: a render function (`st -> view-model`),
a setup function (`() -> st` or `st -> st`, producing the initial state), and
an optional parent mode for keymap inheritance. A mode is a *class*, not an
instance — mode-local state is out of scope here. Internally a mode record is
a 5-slot vector `[name keymap render setup parent]`.

Load with:

```lisp
(load "editor/50-keymap.lsp")
(load "editor/52-mode.lsp")
```

#### `(define-major-mode name opts)`

Define (or redefine) a major mode. `opts` is a flat plist:
`(:keymap km :render render-fn :setup setup-fn :parent parent-name)` — all
keys optional. A keymap is auto-created when `:keymap` isn't supplied. Stores
the record in the mode registry **and** registers the keymap into
`50-keymap`'s `*keymaps*`, so plain `mode-dispatch` still works on it.

- **Parameters:** `name` — a mode-name keyword; `opts` — a flat plist of `:keymap`/`:render`/`:setup`/`:parent`, or `nil` for all-defaults.
- **Returns:** `name`.

```lisp
(define-major-mode ':m-ret nil)  ; => :m-ret
```

#### `(major-mode name)`

- **Parameters:** `name` — a mode-name keyword.
- **Returns:** the raw mode record (vector), or `nil` if undefined.

#### `(major-mode? name)`

- **Returns:** `t` if `name` is a defined mode, else `nil`.

#### `(major-mode-list)`

- **Returns:** the list of all defined mode names.

#### `(major-mode-keymap name)` / `(major-mode-render name)` / `(major-mode-setup name)` / `(major-mode-parent name)`

Field accessors on a mode record.

- **Parameters:** `name` — a mode-name keyword.
- **Returns:** the respective field (keymap / render fn / setup fn / parent name), or `nil` if the mode is undefined or the field wasn't supplied.

```lisp
(define-major-mode ':m-empty nil)
(major-mode-render ':m-empty)  ; => nil
(major-mode-setup  ':m-empty)  ; => nil
(major-mode-parent ':m-empty)  ; => nil
(major-mode-keymap ':m-empty)  ; => a keymap (auto-created, never nil)
```

#### `(major-mode-handler name token event-type)`

Resolve a handler for `token` by checking `name`'s own keymap first, then
walking the `:parent` chain (child overrides parent). Bounded to
`MAJOR-MODE-MAX-DEPTH` (32) steps so a malformed parent cycle terminates
instead of looping forever.

- **Parameters:** `name` — a mode-name keyword; `token` — the command token; `event-type` — `:tap`/`:double-tap`/`:long-press`.
- **Returns:** the resolved handler function, or `nil`.

```lisp
;; pk binds CAR and CDR; ck (child) overrides only CAR
(major-mode-handler ':m-child 'CDR ':tap)  ; => the parent's CDR handler
```

#### `(major-mode-dispatch name token event-type st)`

Like `50-keymap`'s `mode-dispatch`, but inheritance-aware (uses
`major-mode-handler`). Unbound token or unknown mode is a no-op.

- **Parameters:** `name` — a mode-name keyword; `token`, `event-type`, `st` — as elsewhere.
- **Returns:** the next state, or `st` unchanged.

```lisp
;; child's own CAR binding wins, CDR falls through to the parent
(major-mode-dispatch ':m-child 'CAR ':tap nil)  ; => (child-car)
(major-mode-dispatch ':m-child 'CDR ':tap nil)  ; => (parent-cdr)
```

#### `(major-mode-enter name st)`

Run the mode's setup function against `st`. A `nil` setup (or an unknown mode)
returns `st` unchanged. Because `setup` is applied *to* `st`, both a
`(() -> st)` initial-state function and an `(st -> st)` transform work, relying
on Fe's arity tolerance (the zero-arg form simply ignores the argument).

- **Parameters:** `name` — a mode-name keyword; `st` — the incoming state.
- **Returns:** the state after setup, or `st` unchanged.

```lisp
(define-major-mode ':m-setup (list ':setup (fn () 'initial-state)))
(major-mode-enter ':m-setup 'ignored)  ; => initial-state
```

**Note:** two independently-parented modes that cite each other
(`:m-cyc-a` parented to `:m-cyc-b`, and vice versa) do not infinite-loop —
`major-mode-handler`'s depth counter catches the cycle and returns `nil` once
`MAJOR-MODE-MAX-DEPTH` steps are exhausted, verified directly against
`tests/editor/mode.lsp`'s `parent-cycle-terminates` case.

---

### `editor/55-bindings.lsp` — the default key bindings, as data

Where `50-keymap` is the keymap *engine*, this is the default *binding set* a
terminal host runs: one hash table (`*default-keymap*`) maps canonical key
notation (`"C-n"`, `"C-M-f"`, `"C-x C-s"`) to a **command symbol**. The host
dispatches a normalized keystroke through this table with no command knowledge
of its own — because the table is data, `describe-key`/`where-is` are a few
lines of introspection. This module is device-agnostic: keys are plain
notation strings and commands are editor-tier functions (`text-*`); the
device's own physical-key grammar (50-keymap's `:nemacs-nav` map) lives with
the device host, not here.

A command symbol is either a **buffer command** — a one-argument editor verb
applied to the buffer for effect — or a **host command** (`save-buffer`,
`exit-editor`, `eval-current`, `keyboard-quit`), which the host performs
because it owns terminal + file I/O.

Load with:

```lisp
(load "editor/32-text.lsp")
(load "editor/55-bindings.lsp")
```

#### The keymap-as-data shape

`*default-keymap*` is a plain hash table, `"key-string" -> command-symbol`.
Rebinding a key is a data edit — replace the value at a key — never a code
change. The default bindings (as loaded):

| Key | Command |
|---|---|
| `C-f` / `<right>` | `text-forward!` |
| `C-b` / `<left>` | `text-backward!` |
| `C-n` / `<down>` | `text-next-line!` |
| `C-p` / `<up>` | `text-prev-line!` |
| `C-a` | `text-bol!` |
| `C-e` | `text-eol!` |
| `RET` | `text-newline!` |
| `DEL` | `text-backspace!` |
| `C-d` | `text-delete!` |
| `TAB` | `text-insert-tab!` |
| `C-/` / `C-x u` | `text-undo!` |
| `M-/` | `text-redo!` |
| `C-@` | `text-set-mark!` |
| `C-w` | `text-kill-region!` |
| `M-w` | `text-kill-ring-save!` |
| `C-y` | `text-yank!` |
| `C-k` | `text-kill-line!` |
| `C-x C-s` | `save-buffer` (host) |
| `C-x C-c` | `exit-editor` (host) |
| `C-g` | `keyboard-quit` (host) |

#### `(bind-key key cmd)`

Bind a key-string to a command symbol in `*default-keymap*` — this **is** the
rebinding mechanism: call it again with the same key to replace the binding.

- **Parameters:** `key` — a key-notation string (e.g. `"C-n"`, `"C-x C-s"`); `cmd` — a command symbol.
- **Returns:** `key`.

```lisp
(bind-key "C-q" 'text-forward!)
(key-command "C-q")   ; => text-forward!
(resolve-key "C-q")   ; => "buffer:text-forward!"   (was "undefined" before rebinding)
```

#### `(key-command key)`

The raw lookup behind `describe-key`.

- **Parameters:** `key` — a key-notation string.
- **Returns:** the bound command symbol, or `nil` if unbound.

```lisp
(key-command "C-n")       ; => text-next-line!
(key-command "C-x C-s")   ; => save-buffer
(key-command "C-q")       ; => nil (before rebinding)
```

#### `(where-is cmd)`

Invert the map: every key bound to `cmd`.

- **Parameters:** `cmd` — a command symbol.
- **Returns:** a list of key-strings bound to `cmd` (order not guaranteed); `nil` if none.

```lisp
(where-is 'text-next-line!)  ; => ("C-n" "<down>")
```

#### `(host-command? cmd)`

- **Parameters:** `cmd` — a command symbol.
- **Returns:** `t` if `cmd` is one of the four host-I/O commands (`save-buffer`, `exit-editor`, `eval-current`, `keyboard-quit`), else `nil`.

```lisp
(host-command? 'save-buffer)      ; => t
(host-command? 'text-next-line!)  ; => nil
```

#### `(resolve-key key)`

Classify a normalized keystroke for the host: what kind of action it names.

- **Parameters:** `key` — a key-notation string.
- **Returns:** a tag string — `"buffer:<cmd>"` (apply the editor verb to the buffer), `"host:<cmd>"` (the host performs I/O), `"self-insert"` (an unbound single graphic character), or `"undefined"` (an unbound sequence).

```lisp
(resolve-key "C-n")     ; => "buffer:text-next-line!"
(resolve-key "C-x C-c") ; => "host:exit-editor"
(resolve-key "a")       ; => "self-insert"
(resolve-key "C-q")     ; => "undefined"
```

#### `(describe-key key)`

The echo-area line for `C-h k`.

- **Parameters:** `key` — a key-notation string.
- **Returns:** `"<key> runs <cmd>"`, or `"<key> is undefined"`.

```lisp
(describe-key "C-n")  ; => "C-n runs text-next-line!"
(describe-key "C-q")  ; => "C-q is undefined"
```

---

### `editor/60-persist.lsp` — the serialize/load pair (L7)

Owns *only* the `(serialize, load)` pair — the host owns the bytes (SEAM S5):
`serialize` hands back a string, `load` ingests one. On-disk form is plain
Lisp source (a consequence of using the printer), so an edited buffer is just
a `.lsp` file.

Load with:

```lisp
(load "editor/10-zipper.lsp")
(load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp")
(load "editor/60-persist.lsp")
```

#### `(buffer->string b)`

Serialize a buffer as printable s-expression text: the top-level forms, one
per line, in source order.

- **Parameters:** `b` — a buffer.
- **Returns:** the serialized string; `"()"` for an empty buffer.

```lisp
(buffer->string (make-buffer "empty" nil))       ; => "()"
(buffer->string (mkbuf "s" "(a b c)"))            ; => "(a b c)"
```

#### `(buffer-serialize b cap)`

Like `buffer->string`, but enforces a byte cap for a host that must bound the
output (SEAM S9).

- **Parameters:** `b` — a buffer; `cap` — the maximum byte length the host will accept.
- **Returns:** the serialized string if it fits within `cap` bytes; the integer `0` (a sentinel) if it would exceed `cap` — the host gets no output on overflow, not a truncated string.

```lisp
(buffer-serialize (mkbuf "s" "(a b c)") 100)  ; => "(a b c)"
(buffer-serialize (mkbuf "s" "(a b c)") 3)    ; => 0
```

#### `(buffer-load name s)`

Parse `s` into forms (via the reader) and construct a fresh buffer from them.

- **Parameters:** `name` — the buffer's name; `s` — Lisp source text.
- **Returns:** a new buffer named `name`, cursor seated at `(root, 0)` — i.e. on the first top-level form.

```lisp
(let b (buffer-load "round" "(define (f x) (+ x 1))\n(foo (bar baz))"))
(buffer-forms b)  ; => ((define (f x) (+ x 1)) (foo (bar baz)))
(buffer-focus b)  ; => (define (f x) (+ x 1))
```

**Note:** symbol identity is preserved across a `buffer->string` /
`buffer-load` round-trip by intern-by-name (the reader re-interns), so
`(equal? (buffer-forms b) (buffer-forms (buffer-load "r2" (buffer->string b))))`
holds structurally even though it's a completely fresh parse.

#### `(buffer-reload! b s)`

Replace `b`'s root **in place** from text `s`: re-parses `s`, resets the
cursor to the new root, and clears modified-flag, clipboard, and any pending
literal-entry state.

- **Parameters:** `b` — the buffer to overwrite; `s` — the replacement Lisp source text.
- **Returns:** `b`.

```lisp
(let b (mkbuf "s" "(a b c)"))
(buffer-descend! b) (buffer-insert-leaf! b 'z)  ; make it modified
(buffer-reload! b "(x y)")
(buffer-forms b)      ; => ((x y))
(buffer-focus b)      ; => (x y)   (cursor reset to the new root)
(buffer-modified? b)  ; => nil     (cleared)
(buffer-clipboard b)  ; => nil     (cleared)
```

---

### `editor/70-lifecycle.lsp` — the session state machine + hooks (L8)

Owns the lifecycle **state** and fires **hooks** the host subscribes to
(SEAM S6); it performs no device side effects itself. Entering the editor,
pausing CIPHER, preserving a framebuffer, etc. are the host's job, run from
its hook callbacks. States flow `:init -> :editor | :repl -> ... -> :exited`
or `:shutdown`. A lifecycle record is a 3-slot vector `[state mode hooks]`,
where `hooks` is an alist of `(event . fn)`.

Load with:

```lisp
(load "editor/70-lifecycle.lsp")
```

#### `(make-lifecycle)`

- **Returns:** a new lifecycle in state `:init`, mode `nil`, no hooks.

```lisp
(let lc (make-lifecycle))
(lifecycle-state lc)  ; => :init
(lifecycle-mode lc)   ; => nil
```

#### `(lifecycle-state lc)` / `(lifecycle-mode lc)`

Field accessors.

- **Parameters:** `lc` — a lifecycle.
- **Returns:** the current state keyword, or the current mode keyword (`nil` if none set).

#### `(lifecycle-add-hook lc event fn)`

Subscribe `fn` to `event`. `:enter` and `:exit` hooks are called as `(fn lc)`;
`:mode-change` hooks as `(fn lc mode)`. Multiple hooks may subscribe to the
same event; all run, most-recently-added first (hooks are consed onto the
front of the list).

- **Parameters:** `lc` — a lifecycle; `event` — `:enter`, `:exit`, or `:mode-change`; `fn` — the callback.
- **Returns:** `lc`.

```lisp
(let lc (make-lifecycle))
(let n 0)
(lifecycle-add-hook lc ':enter (fn (x) (set n (+ n 1))))
(lifecycle-add-hook lc ':enter (fn (x) (set n (+ n 10))))
(lifecycle-enter-editor! lc)
n  ; => 11  (both hooks ran)
```

#### `(lifecycle-enter-editor! lc)`

Transition to state `:editor`; fires `:enter` hooks with the lifecycle
(already in its new state).

- **Parameters:** `lc` — a lifecycle.
- **Returns:** `lc`.

#### `(lifecycle-enter-repl! lc)`

Transition to state `:repl`; fires `:enter` hooks.

- **Parameters:** `lc` — a lifecycle.
- **Returns:** `lc`.

#### `(lifecycle-exit! lc)`

Transition to state `:exited`; fires `:exit` hooks (not `:enter`).

- **Parameters:** `lc` — a lifecycle.
- **Returns:** `lc`.

```lisp
(let lc (make-lifecycle))
(let exits 0)
(lifecycle-add-hook lc ':exit (fn (x) (set exits (+ exits 1))))
(lifecycle-enter-editor! lc)
(lifecycle-exit! lc)
(lifecycle-state lc)  ; => :exited
exits                 ; => 1
```

#### `(lifecycle-shutdown! lc)`

Transition to state `:shutdown`; fires `:exit` hooks (shutdown and exit share
the `:exit` hook channel — a hook that cares can distinguish them via
`(lifecycle-state lc)` inside the callback, which already reads the new
state).

- **Parameters:** `lc` — a lifecycle.
- **Returns:** `lc`.

#### `(lifecycle-set-mode! lc mode)`

Set the active keymap scope (one of the five `MODE-*` constants from
`50-keymap`, though this module doesn't enforce that); fires `:mode-change`
hooks with `(lc mode)`.

- **Parameters:** `lc` — a lifecycle; `mode` — the new mode keyword.
- **Returns:** `lc`.

```lisp
(let lc (make-lifecycle))
(let seen nil)
(lifecycle-add-hook lc ':mode-change (fn (x mode) (set seen mode)))
(lifecycle-set-mode! lc ':repl-prompt)
(lifecycle-mode lc)  ; => :repl-prompt
seen                 ; => :repl-prompt
```

---

### `editor/72-timer.lsp` — the idle-timer registry (ADR-0006)

The Lisp half of knEmacs's idle-timer (Emacs's `run-with-timer`). The **host**
owns the clock and the event loop; this registry owns only *scheduling*, in
abstract seconds. Every entry point takes the current absolute time `now` as
an explicit argument rather than calling `(now)` itself, which makes the
whole module deterministically testable against a mock clock (as
`tests/editor/timer.lsp` does — no real time anywhere in its 27 checks) and
lets the device firmware drive it from whatever clock it has.

A timer is a 4-slot vector `[id due repeat fn]` (`id` — integer handle for
`cancel-timer`; `due` — absolute fire time; `repeat` — reschedule interval in
seconds, or `nil` for one-shot; `fn` — a zero-argument thunk).

**The host main-loop contract** (from the header comment — this is what
`cli/main.c do_nemacs` does each iteration):

```
ms = (timers-poll-ms (now))     ; -1 when nothing is armed -> block as before
... poll(stdin, ms) ...
on timeout: (timers-advance! (now))   ; fire due thunks, re-arm repeats
```

Load with:

```lisp
(load "editor/72-timer.lsp")
```

#### `(run-with-timer secs repeat fn now)`

Arm `fn` to fire once at `now + secs`. If `repeat` is a **positive** number,
the timer re-arms every `repeat` seconds after firing; `nil` or a
non-positive number makes it a one-shot.

- **Parameters:** `secs` — seconds from `now` until first fire; `repeat` — reschedule interval in seconds, or `nil`/non-positive for one-shot; `fn` — a zero-argument thunk, called for side effect; `now` — the current absolute time (host-supplied).
- **Returns:** the new timer's integer id (pass to `cancel-timer`).

```lisp
(cancel-all-timers!)
(let hits 0)
(run-with-timer 1 nil (fn () (set hits (+ hits 1))) 0)
(timers-advance! 0.5)  ; => 0   (not due yet)
(timers-advance! 1.0)  ; => 1   (due at t=1, fires)
hits                   ; => 1
(timers-advance! 2.0)  ; => 0   (one-shot already consumed)
```

**Note:** the non-positive `repeat` guard is load-bearing, not cosmetic. In
KEC, `0` is truthy — an unguarded `repeat` of `0` would re-arm to `now+0`
(always due) and spin the host's poll loop forever. `run-with-timer`
normalizes it to a one-shot instead; verified with `(run-with-timer 1 0 ...)`
firing exactly once and leaving the registry empty afterward (same for a
negative repeat like `-3`).

#### `(cancel-timer id)`

Remove the timer with this id. A no-op (no error) if the id is absent —
already fired, already cancelled, or never existed.

- **Parameters:** `id` — a timer id returned by `run-with-timer`.
- **Returns:** `id`.

```lisp
(let id (run-with-timer 1 1 (fn () nil) 0))
(cancel-timer id)
(timers-advance! 5.0)  ; => 0   (nothing fires — it was cancelled)
```

#### `(cancel-all-timers!)`

Drop every armed timer. Mainly for test isolation (every test in
`tests/editor/timer.lsp` opens with this).

- **Returns:** `nil`.

#### `(timers-next-delay now)`

The number of seconds until the soonest due timer, clamped to a minimum of 0
for timers already past due.

- **Parameters:** `now` — the current absolute time.
- **Returns:** a non-negative number, or `nil` if no timers are armed.

```lisp
(cancel-all-timers!)
(timers-next-delay 0)  ; => nil
```

#### `(timers-poll-ms now)`

The value the host hands straight to `poll()`: milliseconds until the
soonest due timer, floored.

- **Parameters:** `now` — the current absolute time.
- **Returns:** `-1` when nothing is armed (block forever — byte-identical to the pre-timer editor loop), else a non-negative integer millisecond count.

```lisp
(cancel-all-timers!)
(timers-poll-ms 0)  ; => -1

(run-with-timer 2 nil (fn () nil) 0)
(timers-poll-ms 0)    ; => 2000
(timers-poll-ms 1.5)  ; => 500
(timers-poll-ms 3)    ; => 0     (overdue -> 0, fire now)
```

#### `(timers-advance! now)`

Fire every timer whose due time has arrived as of `now`; re-arm repeats to
`now + repeat`, drop one-shots. The due set is **snapshotted and the registry
rebuilt before any thunk runs**, so a thunk can safely call
`cancel-timer`/`run-with-timer` mid-fire without corrupting the walk.

- **Parameters:** `now` — the current absolute time.
- **Returns:** the count of timers that fired this call.

```lisp
(cancel-all-timers!)
(run-with-timer 1 1 (fn () nil) 0)
(timers-advance! 1.0)  ; => 1  (fires, re-arms for t=2)
(timers-advance! 1.5)  ; => 0  (not due yet)
(timers-advance! 2.0)  ; => 1  (fires again)
```

**Note (verified against `tests/editor/timer.lsp`'s `reentrancy-add-during-fire`
case):** a thunk that arms a *new* timer mid-fire does not see it fire in the
same `timers-advance!` call, even if the new timer's due time is `<= now` —
the due set was already snapshotted before the thunk ran. Symmetrically, a
timer already captured in this tick's due snapshot still fires this tick even
if a co-due sibling's thunk cancels it first — cancellation only affects
*future* ticks, matching Emacs's behavior. Also: a due repeat fires **exactly
once** per `timers-advance!` call and re-anchors to `now + repeat`, even after
a large clock jump — missed periods are not replayed.

```lisp
(cancel-all-timers!)
(let outer 0) (let inner 0)
(run-with-timer 1 nil
  (fn () (set outer (+ outer 1))
         (run-with-timer 1 nil (fn () (set inner (+ inner 1))) 1))
  0)
(timers-advance! 1.0)  ; => 1 ; outer=1, inner=0 (the new timer didn't fire yet)
(timers-advance! 2.0)  ; => 1 ; inner=1 (fires on the next advance)
```

---

### `editor/80-ranker.lsp` — the static, deterministic token/completion ranker (L5)

No ML, no randomness: a fixed scoring formula over a legal-position filter,
bounded to a top-8 result with an alphabetic tiebreak. One ranker backs both
REPL prompt completion (`editor/95-host.lsp`'s `host-complete`) and the nEmacs
completion palette. Load order: after Core, no buffer/zipper dependency.

**Scoring.** A candidate is `(name . category)` where category is one of
`special` / `function` / `value` / `binding`. At a given cursor position, only
some categories are *legal* — `legal-categories` maps position to the allowed
set (`function` position: `special`+`function`; `argument` position:
`function`+`value`+`binding`; `binding` position: `binding` only; `root`
position: `special`+`function`). Candidates outside the legal set, and any
candidate matching a name in the `builtins` index, are dropped before scoring
— builtins can never be shadowed. Surviving candidates are scored by
`score-token`:

| Signal | Points |
|---|---|
| in the domain-vocabulary index | +5 |
| in the local-bindings set (in scope now) | +3 |
| recency (nearest occurrence in recent history) | 0–10, exponential-ish decay (`10 * 0.9^i` by position back in history, precomputed at load into `*decay-vec*`) |
| popularity (host-fed index) | 0–4 |
| semantic-fit (host-fed set) | +1 |

Ties are broken alphabetically (`string-less?`, a hand-rolled lexicographic
comparison since there is no built-in `string<`). The result is held to the
top 8 via `topn-insert`, an insertion into a bounded best-first list — no full
sort of the candidate set.

Worked example: candidates `map`/`filter`/`foldl`/`car` (functions) and
`xs`/`acc` (bindings), with `map`/`filter`/`foldl` in the domain vocabulary and
`car` a builtin (`map` popularity 4, `filter` popularity 2):

```lisp
(load "editor/80-ranker.lsp")
(let cands (list (cons "map" 'function) (cons "filter" 'function)
                  (cons "foldl" 'function) (cons "car" 'function)
                  (cons "xs" 'binding) (cons "acc" 'binding)))
(let idx (ranker-index (list "map" "filter" "foldl")
                       (list (cons "map" 4) (cons "filter" 2))
                       (list "car" "cdr")))
(rank cands (ranker-context 'function nil nil nil) idx)
; => ((9 . "map") (7 . "filter"))
```
`map` scores 5 (vocab) + 4 (popularity) = 9; `filter` scores 5 + 2 = 7;
`foldl` would score 5 but the ranker only returns non-zero-filtered legal
candidates present — here `car` is excluded as a builtin and `xs`/`acc` are
illegal at a `function` position, so only `map`/`filter` (and `foldl` at 5)
survive the filter; `rank-tokens` gives just the names in order.

#### `(legal-categories pos)`

Maps a cursor position symbol (`'function` / `'argument` / `'binding` /
`'root`, or anything else) to the list of candidate categories legal there.

- **Parameters:** pos — a position symbol.
- **Returns:** a list of category symbols.

```lisp
(legal-categories 'argument)  ; => (function value binding)
```

#### `(category-legal? cat legal)`

- **Parameters:** cat — a category symbol; legal — a list of legal categories (as from `legal-categories`).
- **Returns:** `t` if `cat` is a member of `legal`, else `nil`.

```lisp
(category-legal? 'binding (legal-categories 'argument))  ; => t
```

#### `(build-recency history)`

Builds a token → recency-score hash from a history list (most-recent first),
using the precomputed decay vector. When a token occurs more than once in the
window, the **nearest** occurrence's (highest) score wins.

- **Parameters:** history — a list of token strings, most-recent first.
- **Returns:** a hash table mapping token string → decay score (0–10).

```lisp
(hash-ref (build-recency (list "foldl" "map")) "foldl" 0)  ; => 10
```

#### `(score-token name cat vocab-set pop-hash recency-hash local-set semfit-set)`

Sums the five scoring signals (vocabulary +5, local-binding +3, recency,
popularity, semantic-fit +1) for one candidate.

- **Parameters:** name — candidate token string; cat — its category (unused directly by scoring, present for symmetry with `rank`'s filter step); vocab-set/local-set/semfit-set — hash-tables used as sets (`hash-has?`); pop-hash/recency-hash — hash tables mapping name → numeric score.
- **Returns:** the total integer score.

#### `(topn-insert lst score name cap)`

Inserts `(score . name)` into `lst` (a best-first list of `(score . name)`,
length ≤ `cap`), keeping it sorted best-first (`better?`: higher score wins,
alphabetic tiebreak) and trimmed to `cap`.

- **Parameters:** lst — the current best-first list; score/name — the new candidate's score and name; cap — the maximum length to retain.
- **Returns:** the updated best-first list, length ≤ `cap`.

#### `(ranker-index vocab-names pop-alist builtin-names)`

Builds the precomputed index the host feeds once via SEAM S8 (vocabulary
feed) — turns plain lists/alists into the hash tables `rank` needs.

- **Parameters:** vocab-names — list of domain-vocabulary token strings; pop-alist — alist of `(name . popularity)`, popularity 0–4; builtin-names — token strings that must never be suggested.
- **Returns:** an alist `((vocab . <hash>) (pop . <hash>) (builtins . <hash>))`.

```lisp
(ranker-index (list "map" "filter") (list (cons "map" 4)) (list "car"))
; => ((vocab . #<ptr>) (pop . #<ptr>) (builtins . #<ptr>))
```

#### `(ranker-context pos history locals semfit)`

Builds the per-call context alist `rank` consumes.

- **Parameters:** pos — the cursor's position symbol; history — recent token strings, most-recent first; locals — list of in-scope local-binding names; semfit — list of names the host judges semantically fitting.
- **Returns:** an alist `((pos . pos) (history . history) (locals . <set>) (semfit . <set>))`.

#### `(rank candidates ctx idx)`

The ranker itself: filters `candidates` (a list of `(name . category)`) to
those legal at `ctx`'s position and not in the builtins index, scores each,
and returns the top 8.

- **Parameters:** candidates — list of `(name . category)`; ctx — from `ranker-context`; idx — from `ranker-index`.
- **Returns:** a best-first list of `(score . name)`, length ≤ 8.

```lisp
(rank (list (cons "alpha" 'function) (cons "beta" 'function))
      (ranker-context 'function nil nil (list "beta"))
      (ranker-index (list "alpha" "beta") (list (cons "alpha" 3)) nil))
; => ((8 . "alpha") (6 . "beta"))
```
(`alpha`: vocab +5, popularity +3 = 8; `beta`: vocab +5, semantic-fit +1 = 6.)

#### `(rank-tokens candidates ctx idx)`

Same as `rank`, but returns just the names — this is what the REPL prompt and
the nEmacs popup actually render.

- **Returns:** a best-first list of name strings, length ≤ 8.

```lisp
(rank-tokens (list (cons "map" 'function) (cons "filter" 'function))
             (ranker-context 'function nil nil nil)
             (ranker-index (list "map" "filter") (list (cons "map" 4) (cons "filter" 2)) nil))
; => ("map" "filter")
```

---

### `editor/85-minibuffer.lsp` — completing-read + command-by-name (the M-x surface)

Three headless, display-free pieces promoted toward the application-engine
layer (kn-86 ADR-0046 Decision 2): a command registry, ido-style
`completing-read`, and a small minibuffer state record. Load order: after
80-ranker (reuses `string-less?`), before 90-repl.

#### `(define-command name fn)`

Registers `fn` under the string `name` in the global command registry (the
M-x target table).

- **Parameters:** name — a command-name string; fn — the function to invoke.
- **Returns:** `name`.

```lisp
(define-command "save-buffer" (fn () 'saved))  ; => "save-buffer"
```

#### `(command name)`

- **Parameters:** name — a command-name string.
- **Returns:** the registered function, or `nil` if unregistered.

#### `(command? name)`

- **Returns:** `t` if `name` is registered, else `nil`.

```lisp
(command? "save-buffer")  ; => t
(command? "no-such-command")  ; => nil
```

#### `(command-names)`

- **Returns:** the list of all registered command-name strings (unordered — a hash-table key dump).

#### `(completing-read candidates query)`

ido-style incremental narrowing. An empty or `nil` query returns all
candidates unchanged. Otherwise partitions into prefix matches and substring
matches, alphabetizes each group independently, and returns prefix-group
followed by substring-group. Deterministic and iterative.

- **Parameters:** candidates — a list of strings; query — a search string, or `nil`/`""` for no filtering.
- **Returns:** the filtered, reordered candidate list.

```lisp
(completing-read (list "grape" "apple" "map") "ap")
; => ("apple" "grape" "map")
```
`"ap"` is a prefix of `"apple"` and only a substring of `"grape"`/`"map"`, so
`apple` sorts first even though `grape` is alphabetically earlier.

#### `(make-minibuffer prompt candidates)`

- **Parameters:** prompt — a prompt string; candidates — the full candidate list to narrow over.
- **Returns:** a fresh minibuffer record (a 3-slot vector `[prompt input candidates]`) with empty input.

#### `(minibuffer-prompt mb)` / `(minibuffer-input mb)`

Accessors for the prompt string and the current (possibly partial) input string.

```lisp
(let mb (make-minibuffer "M-x " (list "save" "quit")))
(minibuffer-prompt mb)  ; => "M-x "
(minibuffer-input mb)   ; => ""
```

#### `(minibuffer-update mb input)`

Records `input` as the minibuffer's current text. Mutates `mb` in place (like
the buffer/lifecycle records elsewhere in the tier) and also returns it.

- **Parameters:** mb — a minibuffer record; input — the new input string.
- **Returns:** `mb`.

#### `(minibuffer-matches mb)`

- **Returns:** `(completing-read <mb's candidates> (minibuffer-input mb))` — the current narrowed list, recomputed on demand (not cached).

```lisp
(let mb (make-minibuffer "M-x " (list "save" "save-all" "quit")))
(set mb (minibuffer-update mb "sa"))
(minibuffer-matches mb)  ; => ("save" "save-all")
```

#### `(minibuffer-default mb)`

- **Returns:** the first (best-ranked) match, or `nil` if nothing matches the current input.

```lisp
(minibuffer-default mb)  ; => "save"   (continuing the example above)
```

#### `(execute-command name . args)`

Looks up `name` in the registry and applies it to `args`.

- **Parameters:** name — a registered command-name string; args — arguments to apply.
- **Returns:** the command's return value.

**Note:** raises an error (not `nil`) for an unregistered name — verified:
`(execute-command "definitely-not-a-command")` signals `execute-command:
unknown command: definitely-not-a-command` rather than failing silently.

```lisp
(define-command "echo-it" (fn (x) (cons 'echoed x)))
(execute-command "echo-it" 'payload)  ; => (echoed . payload)
```

#### `(read-command query)`

- **Parameters:** query — a search string over command names.
- **Returns:** `(completing-read (command-names) query)` — the narrowed list of command names; the host picks one and calls `execute-command`.

```lisp
(read-command "echo")  ; => ("echo-it")
```

---

### `editor/90-repl.lsp` — the read-eval-print loop engine (L6)

The onboard REPL loop, host-agnostic. Requires `eval` (the FULL/editor tier);
load order: after 50-keymap.

**The submit/entry-output cycle.** `repl-submit` is the whole cycle in one
call: it clears any active history walk, and for a non-`nil` input form it
evaluates the form against the repl's bound eval-fn *inside* `try` — so a
raising form does not propagate out of the loop. The outcome becomes a
3-field entry (`make-repl-entry`: input, output, ok?):

- success → output is `repl-format`'s printed rendering of the result, ok? is `t`.
- failure → output is `"error: " + (error-message ...)`, ok? is `nil`, and the *original input* is preserved in the entry (so the host can let the user retry/edit it).

The entry is then pushed onto the history ring (`%repl-push!`, L6.4): a
submission identical to the most recent one *coalesces* (no new entry, dedup
on consecutive repeats only) instead of growing the ring, and the ring evicts
its oldest entry once at capacity. `repl-submit` returns `(entry . r)` —
`entry` is `nil` for an empty (`nil`) submission, which the host should treat
as "nothing to echo."

```lisp
(load "editor/10-zipper.lsp") (load "editor/20-undo.lsp")
(load "editor/30-buffer.lsp") (load "editor/50-keymap.lsp")
(load "editor/90-repl.lsp")
(let r (make-repl 16 40 nil))
(let res (repl-submit r (read-string "(+ 1 2)")))
(list (entry-input (car res)) (entry-output (car res)) (entry-ok? (car res)) (repl-count r))
; => ((+ 1 2) "3" t 1)
```

#### `(make-repl-entry input output ok)` / `(entry-input e)` / `(entry-output e)` / `(entry-ok? e)`

A history entry is a 3-element list. The three accessors read it back.

- **Parameters (constructor):** input — the submitted form; output — the printed result or error string; ok — `t`/`nil`.
- **Returns:** the entry (constructor), or the corresponding field (accessors).

#### `(make-repl capacity width eval-fn)`

Builds a fresh repl record — a 5-slot vector `[history capacity width
eval-fn walk]`.

- **Parameters:** capacity — max history-ring entries; width — the line-budget width for `repl-format`'s pretty-printer; eval-fn — the function to evaluate submitted forms with, or `nil` to default to the global `eval`.
- **Returns:** a repl record.

```lisp
(make-repl 16 40 nil)  ; capacity 16, width 40, eval-fn defaults to `eval`
```

#### `(repl-history r)` / `(repl-capacity r)` / `(repl-width r)` / `(repl-eval-fn r)` / `(repl-walk r)` / `(repl-count r)`

Field accessors. `repl-history` returns the entry list, most-recent first;
`repl-walk` is the current history-walk index (`nil` when at the live
prompt); `repl-count` is `(length (repl-history r))`.

#### `(%opaque? v)` / `(%type-name v)` / `(%display1 v)` / `(%repl-truncate s n)` / `(%pp ...)` / `(%pp-break ...)` / `(%pp-append-last ...)`

Private (`%`-prefixed) helpers behind `repl-format` — not documented as
entries.

#### `(repl-format r value)`

The structural pretty-printer (L6.3): renders `value` on one line if it fits
`(repl-width r)`; otherwise breaks it across indented lines (nested structure
indented by depth, recursion capped at `PP-MAX-DEPTH` = 8), and truncates the
whole rendering to `PP-LINE-BUDGET` = 40 lines with a `"... (N more lines)"`
trailer if it's still too long. Opaque values (functions, macros, cfuncs,
prims, pointers) render as a `#<type>` tag rather than attempting to print
their internals.

- **Parameters:** r — a repl record (supplies the width); value — any Lisp value.
- **Returns:** the formatted string.

```lisp
(let r (make-repl 16 12 nil))
(repl-format r (read-string "(define (f x) (g x))"))
; => "(define\n (f x)\n (g x))"
```

**Note:** opaque values print as bare type tags with no distinguishing detail
— verified `(fn (x) x)` formats as `"#<fn>"` and `(vector 1 2)` as `"#<ptr>"`
(vectors are host pointer objects, not a distinct printer type).

#### `(repl-submit r input)`

See the cycle description above.

- **Parameters:** r — a repl record; input — a well-formed form, or `nil` for an empty submission.
- **Returns:** `(entry . r)` — `entry` is `nil` for an empty submission.

#### `(repl-recall r)`

- **Returns:** the history entry currently selected by the walk index, or `nil` if not walking (at the live prompt).

#### `(repl-older! r)`

Moves the walk index one step toward older history (first call from the
prompt lands on the *newest* entry, index 0); mutates and returns `r`.
Clamped at the oldest entry.

#### `(repl-newer! r)`

Moves the walk index one step toward newer history; stepping past the
newest entry returns to the live prompt (`walk` becomes `nil`). Mutates and
returns `r`.

```lisp
(let r (make-repl 16 40 nil))
(repl-submit r (read-string "1"))
(repl-submit r (read-string "2"))
(repl-older! r)                       ; -> newest (2)
(entry-input (repl-recall r))         ; => 2
(repl-older! r)                       ; -> 1
(entry-input (repl-recall r))         ; => 1
(repl-newer! r) (repl-newer! r)       ; back to the prompt
(repl-recall r)                       ; => nil
```

#### `(repl-reeval! r)`

Re-submits the currently recalled entry's input as a fresh submission (a new
`repl-submit` call, subject to the same coalesce/evict rules). No-op
(`(cons nil r)`) if nothing is recalled.

- **Returns:** the same `(entry . r)` shape as `repl-submit`.

```lisp
(let r (make-repl 16 40 nil))
(repl-submit r (read-string "(+ 10 5)"))
(repl-older! r)
(repl-reeval! r)
(entry-output (car (repl-history r)))  ; => "15"
```

#### `(repl-run-guided r prompts)`

Runs a scripted list of `(input . expected)` pairs against the repl's eval-fn
**without** touching the history ring — the guided-prompt (tutorial) runner
mechanism (L6.7); walkthrough content and the first-boot trigger are DEVICE
concerns layered on top by the firmware.

- **Parameters:** r — a repl record; prompts — a list of `(input . expected-value)` pairs.
- **Returns:** a list of `(input pass?)` pairs, one per prompt.

```lisp
(repl-run-guided r (list (cons (read-string "(+ 1 1)") 2)
                          (cons (read-string "(+ 2 2)") 5)))  ; second is wrong on purpose
; => (((+ 1 1) t) ((+ 2 2) nil))
```

#### `*repl-history-keymap*`

The default `:repl-history` mode keymap (not a function, but a public
top-level binding): `CDR` → `repl-older!`, `QUOTE` → `repl-newer!`, `EVAL` →
`repl-reeval!` (then returns the repl). Registered against `MODE-REPL-HISTORY`
via `register-keymap` at load time.

---

### `editor/92-prompt.lsp` — the structural REPL prompt (`:repl-prompt`)

The REPL's input side: the prompt itself is a structural buffer (the same
tree-buffer type as the editor), composed with the ordinary editor verbs;
`EVAL` submits the current top-level form to a REPL engine and resets the
prompt. Load order: after 30-buffer, 50-keymap, 60-persist, 90-repl.

#### `(make-prompt-session repl)`

- **Parameters:** repl — a repl record (from `make-repl`).
- **Returns:** a prompt-session (2-slot vector `[prompt-buffer repl]`) — a fresh `*prompt*` buffer seeded with `()`, paired with `repl`.

#### `(prompt-buffer ps)` / `(prompt-repl ps)`

Accessors for the prompt session's buffer and repl.

#### `(prompt-submit! ps)`

Submits the prompt buffer's current top-level form to `(prompt-repl ps)` via
`repl-submit`, then resets the prompt buffer back to `()`.

- **Parameters:** ps — a prompt session.
- **Returns:** the new history entry.

```lisp
(let r (make-repl 16 40 nil))
(let ps (make-prompt-session r))
(buffer-reload! (prompt-buffer ps) "(+ 1 2)")
(mode-dispatch MODE-REPL-PROMPT 'EVAL ':tap ps)   ; EVAL submits via the keymap
(repl-count r)                                     ; => 1
(entry-output (car (repl-history r)))              ; => "3"
(buffer-forms (prompt-buffer ps))                  ; => (nil)  -- reset to "()"
```

#### `*repl-prompt-keymap*`

The default `:repl-prompt` mode keymap (public top-level binding, not a
function): structural navigation/editing verbs (`CAR` descend, `CDR` next
sibling, `QUOTE` prev sibling, `BACK` ascend, `CONS` wrap) over the prompt
buffer, plus `EVAL` bound to `prompt-submit!`. All handlers take and return
the prompt-session. Registered against `MODE-REPL-PROMPT`.

---

### `editor/95-host.lsp` — a reference host session (SEAM wiring)

This is the file a firmware engineer should read to know exactly what a new
host must supply. ADR-0002 defines the SEAM as nine abstract capabilities
(S1–S9) that LIB depends on and that carry **no device vocabulary**; this
module is the minimal, concrete instance of four of them, wired to a laptop
REPL, proving the engine runs with no KN-86 hardware. Any new host —
including the KN-86 firmware — implements the same four (plus, depending on
what it uses, the remaining S2/S3/S5–S7/S9 seams from ADR-0002) against its
own substrate: **S1 (evaluation context)** is "which primitives are bound
into the eval function you hand the repl" — here it's simply the global
`eval` bound with the FULL profile's primitives; on the device it would be
whatever NoshAPI primitives are bound into the cart/system context. **S2
(input events)** is reduced here to "hand a line of text to
`host-repl-line`" — the host owns turning raw key events into that call; a
real device host would classify tap/double-tap/long-press itself and feed
LIB only the resulting command tokens. **S4 (render sink)** is satisfied by
simply returning the formatted output string from `host-repl-line` for the
caller to print — a richer host paints LIB's abstract view model instead.
**S8 (vocabulary feed)** is dogfooded via `host-complete`, which builds a
ranker index straight from the live global environment (`(globals prefix)`)
rather than a device's cartridge-fed domain vocabulary. Requires the
FULL/eval tier; load order: after 90-repl.

#### `(make-session capacity width)`

- **Parameters:** capacity — repl history-ring capacity; width — the repl's pretty-print line width.
- **Returns:** a session (2-slot vector `[repl mode]`) — a fresh repl bound to the global `eval`, starting in `:repl-prompt` mode.

#### `(session-repl s)` / `(session-mode s)`

Accessors for the session's repl record and current mode symbol.

#### `(host-repl-line s line)`

Reads `line` as a single s-expression, submits it to the session's repl, and
returns the entry's output string. A blank/empty line reads as `nil` and
returns `nil` (nothing to print) rather than erroring — this is how the
onboard REPL survives a bare Enter keypress.

- **Parameters:** s — a session; line — a raw text line.
- **Returns:** the formatted output string, or `nil` for a blank line.

```lisp
(let s (make-session 16 40))
(host-repl-line s "(+ 2 3)")       ; => "5"
(host-repl-line s "(list 1 2 3)")  ; => "(1 2 3)"
(host-repl-line s "   ")           ; => nil
(host-repl-line s "(car 5)")       ; => "error: ..."   (loop survives)
```

#### `(host-complete s prefix)`

- **Parameters:** s — a session (unused beyond having a live image to complete against); prefix — a string prefix.
- **Returns:** up to 8 ranked completion candidate strings from `(globals prefix)`, the live global environment — the laptop-host equivalent of the device's on-screen IntelliSense.

```lisp
(let s (make-session 16 40))
(host-complete s "string-a")  ; => ("string-append")
```

---

### `editor/96-tty.lsp` — the ANSI terminal painter for the structural editor

Turns `40-view`'s abstract, terminal-agnostic view-line records into one ANSI
screen string — this is the DEVICE-shaped half of the S4 render sink for a
TTY host specifically (`40-view`'s `buffer->view-lines` carries no terminal
vocabulary at all). The `kec edit` subcommand prints the result each frame.
Load order: after 40-view and 95-host.

#### `(tty-screen b cols rows)`

Renders the whole screen: an inverted-video modeline (buffer name + modified
marker + a fixed help string), the structural tree body (one line per
`view-line` record, the cursor's line in reverse video), clipped to `rows`,
followed by the echo line. Every line is clipped to `cols`.

- **Parameters:** b — a buffer; cols/rows — the terminal's visible width/height.
- **Returns:** one string containing embedded `\n`s and ANSI SGR escapes (reverse-video on/off).

```lisp
(let b (make-buffer "draft" (read-all "(a b c)")))
(buffer-descend! b)
(tty-screen b 80 24)
; => "\x1b[7m draft  C-n/C-p line ... C-x C-c exit\x1b[0m\ndraft\n  (a b c)\n\x1b[7m    a\x1b[0m\n    b\n    c\n:symbol @ depth 2"
```

**Note:** the echo line defaults to the buffer's type/depth description
(`":symbol @ depth 2"` above) when nothing else has set an explicit echo
message — there's no blank echo state; it always shows something about
point.
