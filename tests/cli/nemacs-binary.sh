#!/bin/sh
# `kec nemacs` on a file containing a NUL byte must refuse to open it — Fe
# strings are C strings, so everything after the first NUL would silently
# vanish, and C-x C-s would write the truncated content back over the
# original — and must leave the file byte-identical. A plain text file still
# opens.
set -eu

kec=$1
tmp=${TMPDIR:-/tmp}/kec-nemacs-binary-$$
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp"

printf 'head\0tail\n' > "$tmp/bin.dat"
cp "$tmp/bin.dat" "$tmp/bin.orig"

if "$kec" nemacs "$tmp/bin.dat" < /dev/null > /dev/null 2> "$tmp/err.txt"; then
    echo "FAIL: nemacs opened a NUL-bearing file (exit 0)" >&2
    exit 1
fi
grep -q 'binary file' "$tmp/err.txt" || {
    echo "FAIL: no 'binary file' message" >&2; cat "$tmp/err.txt" >&2; exit 1; }
cmp -s "$tmp/bin.dat" "$tmp/bin.orig" || {
    echo "FAIL: the refused file was modified" >&2; exit 1; }

# Control: a plain text file still opens (EOF on stdin exits cleanly).
printf 'plain text\n' > "$tmp/plain.txt"
"$kec" nemacs "$tmp/plain.txt" < /dev/null > /dev/null 2>&1 || {
    echo "FAIL: plain file no longer opens" >&2; exit 1; }

echo "nemacs-binary OK"
