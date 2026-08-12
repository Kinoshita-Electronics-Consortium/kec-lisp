---
title: "ADR-0007: Network Primitives and JSON"
description: Accepted addition of six FULL-profile TCP socket primitives plus sleep, with HTTP/1.1, chunked transfer decoding, URL encoding, and JSON written in KEC Lisp above them. TLS terminates outside the process. No new link dependency.
---

- **Status:** Accepted
- **Date:** 2026-08-11
- **Deciders:** KEC Lisp maintainers
- **Supersedes / superseded by:** —
- **Builds on:** [ADR-0003](ADR-0003-container-types-vectors-hash-tables.md) (hash tables and vectors, which JSON decodes into and stacks on), [ADR-0006](ADR-0006-host-input-and-idle-timer-seam.md) (the host-seam precedent)

## Context

Nothing in the language could open a socket or read JSON. `host/` registered no
socket, HTTP, TLS, or JSON primitive, and `kec` linked nothing but `libm`.

The motivating use case is a client for the [Artifacts MMO
API](https://docs.artifactsmmo.com/), an MMO played entirely through HTTP. A
player writes a bot: authenticate, poll character state, issue actions, wait out
a server-supplied cooldown, repeat. Every response is JSON. That is a realistic
exercise of the language as a general scripting tool, and none of it was
possible.

The constraint pulling the other way is the dependency-free property, which
outranks any single feature. `kec` builds from a clean checkout with CMake and a
C11 compiler on Linux and macOS, and the KN-86 firmware vendors the
same sources into a device build. Adding libcurl or OpenSSL would end that for
every consumer, including the ones that never make a network call.

## Decision

### 1. Six TCP primitives in C. Everything above them in Lisp.

`host/net.c` registers `tcp-connect`, `tcp-send`, `tcp-recv`, `tcp-close`,
`tcp-listen`, and `tcp-accept`. `host/host.c` gains `(sleep seconds)`. That is
the whole C surface: POSIX sockets and a `nanosleep`, roughly 400 lines
including comments, readable in one sitting.

HTTP/1.1 request building, response framing (`Content-Length`, chunked transfer
decoding, read-to-EOF), URL encoding, and JSON are written in KEC Lisp. The
split is drawn where C stops being necessary: a socket needs a syscall, a
protocol does not.

Practical consequences of drawing it there:

- The protocol layers are readable, patchable, and testable by anyone who reads
  Lisp, with no rebuild between an edit and a test.
- A protocol bug cannot corrupt the arena or leak a descriptor. The worst it can
  do is return a wrong string.
- The device build pays for the socket layer only if the firmware binds it.

### 2. Raw sockets rather than libcurl

libcurl would supply HTTP, TLS, redirects, and cookies at the cost of a link
dependency for every consumer of this repo, a build that no longer works from a
clean checkout with just CMake, a large C attack surface reachable from cart
Lisp, and a second protocol implementation that the KN-86 device would carry
without using most of it.

Against that: HTTP/1.1 request-response framing is a few hundred lines of Lisp,
and the parts a client actually needs are the status line, headers,
`Content-Length`, and chunked transfer decoding.

### 3. TLS terminates outside the process

TLS is not implemented and will not be. A local `socat` or `stunnel` listener
holds the TLS session with the origin; KEC Lisp speaks cleartext HTTP to
`127.0.0.1`.

```sh
socat TCP4-LISTEN:8080,reuseaddr,fork OPENSSL:api.artifactsmmo.com:443,verify=1
```

The alternatives were worse. Linking OpenSSL or mbedTLS breaks the
dependency-free build for everyone. Vendoring a TLS stack makes this repo
responsible for tracking CVEs in cryptographic code, which is the one category
of dependency where being slow to patch is dangerous. Writing TLS in Lisp is not
serious.

What the proxy pattern costs: an extra process to run, and a cleartext leg on
the loopback interface that another sufficiently privileged process on the same
machine could read. What it buys: a verified certificate chain (`verify=1`),
using a TLS implementation that is somebody else's job to patch.

`url-parse` raises on an `https://` URL rather than silently downgrading, and
the message names the pattern. Through the proxy the `Host` header must carry
the origin rather than `127.0.0.1`, or the upstream server routes to the wrong
site; the client takes it as a parameter.

### 4. JSON is Core, in Lisp

`core/68-json.lsp` loads between `65-strtool` and `70-sort` and exports
`json-parse` and `json-stringify`.

In Core rather than an example module, because JSON is how a device talks to
anything: cart save data, a config file, a wire protocol. It has the same
standing as `sort` or `format`. In Lisp rather than C, because a parser handling
untrusted input is exactly the code that should not be a C buffer near the
arena, and because the whole thing is a few hundred lines that anyone can read.

The type mapping, which is also the contract:

| JSON | KEC Lisp |
|---|---|
| object | hash table, string keys |
| array | list |
| string | string |
| number | number |
| `true` | `t` |
| `false` | `nil` |
| `null` | `nil` |

Three properties fall out of the language and are documented rather than
papered over:

- **`false` and `null` both decode to `nil`**, because `nil` is the only false
  value. `hash-has?` distinguishes an absent key from a null one. The same
  conflation runs the other way: `nil` is the empty list, so `json-stringify`
  renders it as `"null"` and an empty array does not round-trip.
- **Numbers are single-precision.** `fe_Number` is a C `float`, so integers are
  exact only to ±2²⁴. `16777217` and `16777216` decode to the same value.
  Timestamp arithmetic on epoch seconds is unsafe; ISO 8601 stamps stay strings
  and compare lexically. A test pins the boundary so a future change to the
  number type shows up as a failure.
- **A JSON string is never coerced to a number.** Artifacts returns identifiers
  like `"6a75cffcf2928a45b1993f68"`, and `string->number` on that silently
  yields `6`.

Both directions are **iterative over an explicit vector stack**. `GCSTACKSIZE`
is 256 on the device build, so recursive descent would exhaust the root stack on
nesting depth a server can produce trivially. This matches the reason the list
functions in `core/10-list.lsp` are iterative.

### 5. Handles are typed `FE_TPTR` with a finalizer

A socket handle uses the kernel's composable typed-pointer lifecycle and
two-phase `fe_set_ptr` construction: the pointer object is allocated first with
a NULL backing (the only step that can raise), so an out-of-memory `longjmp`
during handle creation cannot strand a descriptor. The type's finalizer closes
the fd, so a dropped handle leaks nothing, and `tcp-close` marks the handle so
the finalizer never closes a descriptor number the process has since reused.

### 6. `FULL` profile only, and absent without POSIX sockets

Network access is a capability, gated exactly as file I/O is. A `SANDBOX`
context has no socket primitives at all. On a platform without
`<sys/socket.h>`, `host/net.c` compiles to an empty registration function and
the primitives are simply absent; a stub that always raised would be
indistinguishable from a real network failure. Lisp discovers either case the
same way: `(bound? 'tcp-connect)`.

`tcp-listen` binds 127.0.0.1 only. Its purpose is to let the conformance suite
drive both ends of an exchange without touching the outside network.

## Deferred / out of scope

- TLS in process, in any form.
- HTTP/2, keep-alive, connection pooling, redirects (a 3xx is returned as data),
  cookies, multipart, compression.
- Asynchronous I/O and non-blocking sockets as a Lisp-visible concept. The
  primitives block, bounded by a timeout.
- UDP, Unix domain sockets, and listening on a non-loopback address.
- A binary-safe `tcp-recv`. KEC strings are NUL-terminated, so the receive
  contract is capped at text (high bytes survive; a `NUL` truncates). The send
  direction takes a blob verbatim and has no such limit.

## Consequences

- `kec` still links only `libm`. `target_link_libraries(kec kec_core m)` is
  unchanged.
- A KEC Lisp script can talk to any HTTP API, and to an HTTPS one with a proxy
  in front.
- The KN-86 firmware inherits `json-parse` / `json-stringify` in Core with no
  action, and inherits the socket primitives only if it binds a `FULL` context.
- Anything the protocol layers get wrong is fixed by editing Lisp.
- A response body larger than 16 MiB cannot be framed by `Content-Length`,
  because a single-precision number cannot hold the length exactly. The client
  raises rather than mis-framing.

## Acceptance criteria

- `cmake -S . -B build && cmake --build build` succeeds with no new dependency.
- `ctest --test-dir build` is green with no network access and no proxy running.
- `tests/core/json.lsp` covers the type mapping, every escape form including
  surrogate pairs, the `false`/`null` conflation, malformed input with byte
  offsets, nesting deep enough to break a recursive parser, and the
  single-precision boundary.
- `tests/core/net.lsp` and `tests/examples/http.lsp` exercise the primitives and
  the client over loopback, in-process.
- `tests/cli/http-e2e.sh` runs the fully-composed `http-request` path against a
  second `kec` process.
- `tests/c/test_net.c` asserts a `SANDBOX` context has no socket primitives and
  that the finalizer closes a dropped handle's descriptor.

## References

- [Networking](../networking.md): the primitives, the proxy pattern, the client.
- [Core Library Reference](../core-library.md): `json-parse` / `json-stringify`.
- [FFI Bridge](../ffi-bridge.md): typed `FE_TPTR` handles, two-phase
  construction, the pending-buffer contract `net.c` uses.
- [Artifacts MMO API](https://docs.artifactsmmo.com/): the motivating client.
