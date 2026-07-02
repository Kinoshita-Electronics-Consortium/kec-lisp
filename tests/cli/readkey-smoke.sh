#!/bin/sh
# Smoke-test the `read-key` / `poll-key` host input primitives end-to-end:
# pipe bytes into `kec run echo-keys.lsp` and confirm each byte is echoed as its
# code, then that poll-key returns nil (not a hang) once stdin has drained.
# Usage: readkey-smoke.sh <path-to-kec>
set -e
KEC="$1"
if [ -z "$KEC" ]; then echo "usage: readkey-smoke.sh <kec>"; exit 2; fi
SCRIPT="$(dirname "$0")/echo-keys.lsp"

# 'a'=97 'b'=98 'c'=99, then poll-key past EOF -> nil.
out=$(printf 'abc' | "$KEC" run "$SCRIPT")
expected='97
98
99
poll:nil'
if [ "$out" != "$expected" ]; then
  echo "FAIL: read-key/poll-key mismatch"
  echo "--- expected ---"; printf '%s\n' "$expected"
  echo "--- got ---";      printf '%s\n' "$out"
  exit 1
fi

# Empty stdin: read-key returns nil immediately, poll-key too — no hang.
out=$(printf '' | "$KEC" run "$SCRIPT")
if [ "$out" != "poll:nil" ]; then
  echo "FAIL: empty-stdin expected 'poll:nil', got: [$out]"; exit 1
fi

# A NaN timeout must raise a catchable error, not reach the (int) cast (UB) —
# (/ 0 0) is NaN in Fe's unguarded float arithmetic.
out=$(printf '' | "$KEC" eval "(car (try (fn () (poll-key (/ 0 0)))))")
if [ "$out" != ":error" ]; then
  echo "FAIL: (poll-key NaN) expected a catchable :error, got: [$out]"; exit 1
fi

exit 0
