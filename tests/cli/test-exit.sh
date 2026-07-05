#!/bin/sh
# `kec test` must exit nonzero when a suite raises — a crashed run must never
# read as green in CI. Covers both failure paths: a raise inside a deftest
# (isolated by the harness, counted as a FAIL, later tests still run) and a
# raise at file top level (aborts the load, counted by the driver).
set -eu

kec=$1
tmp=${TMPDIR:-/tmp}/kec-test-exit-$$
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp"

# A raise inside a deftest: counted as a failed check, and the deftest after
# it still runs (2 checks total, 1 failed), exit nonzero.
cat > "$tmp/crash.lsp" <<'LSP'
(deftest "raises" (car 5))
(deftest "after-raise" (check (is 1 1)))
LSP
if "$kec" test "$tmp/crash.lsp" > "$tmp/out1.txt" 2>&1; then
  echo "FAIL: suite with a raising deftest exited 0"
  cat "$tmp/out1.txt"
  exit 1
fi
if ! grep -q "2 checks, 1 failed" "$tmp/out1.txt"; then
  echo "FAIL: raise did not isolate — expected '2 checks, 1 failed'"
  cat "$tmp/out1.txt"
  exit 1
fi

# A raise at file top level: aborts that file's load; the driver must still
# exit nonzero even though no *check* failed.
cat > "$tmp/toplevel.lsp" <<'LSP'
(deftest "ok" (check (is 1 1)))
(car 5)
LSP
if "$kec" test "$tmp/toplevel.lsp" > "$tmp/out2.txt" 2>&1; then
  echo "FAIL: top-level raise exited 0"
  cat "$tmp/out2.txt"
  exit 1
fi

# Control: a clean file still exits 0.
cat > "$tmp/clean.lsp" <<'LSP'
(deftest "ok" (check (is 1 1)))
LSP
"$kec" test "$tmp/clean.lsp" > "$tmp/out3.txt" 2>&1

echo "test-exit OK"
