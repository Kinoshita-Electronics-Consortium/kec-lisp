#!/bin/sh
# End-to-end for the fully-composed http-request path: connect, send, read a
# chunked response, close. Both peers are `kec` processes speaking over
# loopback: no outside network, no proxy, and no TLS.
#
# tests/examples/http.lsp covers the two halves of an exchange inside one
# process, which is all a single thread can express (http-request blocks in the
# read). This is the missing piece: a real second process on the other end.
#
# The server binds an ephemeral port and writes the number to a file, so no
# port is hard-coded and a busy machine cannot make this flake.
#
# Usage: http-e2e.sh <path-to-kec> <repo-root>
set -e
KEC="$1"
ROOT="$2"
if [ -z "$KEC" ] || [ -z "$ROOT" ]; then echo "usage: http-e2e.sh <kec> <root>"; exit 2; fi

PORTFILE=$(mktemp "${TMPDIR:-/tmp}/kec-http-e2e.XXXXXX")
rm -f "$PORTFILE"          # its existence is the signal that a port was written
SERVER_PID=""
# Always reap the server and the temp file, including on an early exit, so no
# stray process is left holding a port.
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
    rm -f "$PORTFILE"
}
trap cleanup EXIT INT TERM

"$KEC" run "$ROOT/tests/cli/http-server.lsp" "$PORTFILE" >/dev/null 2>&1 &
SERVER_PID=$!

# Wait for the listener to report its port (bounded: ~5s).
PORT=""
i=0
while [ -z "$PORT" ] && [ "$i" -lt 100 ]; do
    if [ -s "$PORTFILE" ]; then
        PORT=$(tr -dc '0-9' < "$PORTFILE")
    fi
    if [ -z "$PORT" ]; then sleep 0.05; fi
    i=$((i + 1))
done
if [ -z "$PORT" ]; then echo "FAIL: server never reported a port"; exit 1; fi

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
