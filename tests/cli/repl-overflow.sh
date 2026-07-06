#!/bin/sh
# A REPL form larger than the input accumulator must be discarded WHOLE, with
# a diagnostic — not silently dropped chunk-wise while the paren bookkeeping
# still counts it (which submitted a truncated half-form with "balanced"
# counts). The next form must evaluate normally.
set -eu

kec=$1
tmp=${TMPDIR:-/tmp}/kec-repl-overflow-$$
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp"

# One ~17 KB form (over the 16 KB accumulator), then a small valid one.
long=$(awk 'BEGIN { s = ""; for (i = 0; i < 17000; i++) s = s "x"; print "(princ \"" s "\")" }')
{ printf '%s\n' "$long"; printf '(+ 40 2)\n:q\n'; } \
    | "$kec" repl > "$tmp/out.txt" 2> "$tmp/err.txt"

grep -q 'input too long' "$tmp/err.txt" || {
    echo "FAIL: no 'input too long' diagnostic" >&2; cat "$tmp/err.txt" >&2; exit 1; }
grep -q '^42$' "$tmp/out.txt" || {
    echo "FAIL: REPL did not recover after the overflow" >&2; cat "$tmp/out.txt" >&2; exit 1; }

echo "repl-overflow OK"
