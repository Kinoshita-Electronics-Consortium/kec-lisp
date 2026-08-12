#!/bin/sh
# End-to-end for the fully-composed http-request path: connect, send, read a
# chunked response, close. Both peers are `kec` processes speaking over
# loopback: no outside network, no proxy, and no TLS.
#
# tests/examples/http.lsp covers the two halves of an exchange inside one
# process, which is all a single thread can express (http-request blocks in the
# read). This is the missing piece: a real second process on the other end.
#
# Usage: http-e2e.sh <path-to-kec> <repo-root>
set -e
KEC="$1"
ROOT="$2"
if [ -z "$KEC" ] || [ -z "$ROOT" ]; then echo "usage: http-e2e.sh <kec> <root>"; exit 2; fi

PORT=34811
SERVER_PID=""
# Always reap the server, including on an early exit, so no stray process is
# left holding a port (or a CPU).
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

"$KEC" run "$ROOT/tests/cli/http-server.lsp" "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!

# The client retries the connect while the server is still binding, which is
# also an end-to-end exercise of (sleep 0.05).
out=$("$KEC" run "$ROOT/tests/cli/http-client.lsp" "$PORT")

echo "$out" | grep -q '^status=200$' \
    || { echo "FAIL: status"; echo "$out"; exit 1; }
echo "$out" | grep -q '^line=GET /grandexchange/history/copper_ore?size=3 HTTP/1.1$' \
    || { echo "FAIL: request line"; echo "$out"; exit 1; }
# Through a TLS proxy the Host header must name the ORIGIN, not the loopback
# address the socket actually goes to.
echo "$out" | grep -q '^host=api.artifactsmmo.com$' \
    || { echo "FAIL: Host header"; echo "$out"; exit 1; }

wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
exit 0
