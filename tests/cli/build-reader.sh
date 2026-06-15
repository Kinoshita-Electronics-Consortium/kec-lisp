#!/bin/sh
set -eu

kec=$1
tmp=${TMPDIR:-/tmp}/kec-build-reader-$$
src=$tmp/src
run=$tmp/run
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$src" "$run"

cat > "$src/dep.lsp" <<'LSP'
(defn dep-value () "dep-ok")
LSP

cat > "$src/main.lsp" <<'LSP'
(load
  "dep.lsp")

(defn not-used ()
  (load "must-not-inline.lsp"))

(princ (dep-value)) (newline)
LSP

"$kec" build "$src/main.lsp" -o "$run/bundle.kec" >/dev/null

if grep -q "must-not-inline" "$run/bundle.kec"; then
  :
else
  echo "nested load disappeared from bundle" >&2
  exit 1
fi

if grep -q 'load "dep.lsp"' "$run/bundle.kec"; then
  echo "top-level load was not structurally inlined" >&2
  exit 1
fi

out=$(cd "$run" && "$kec" run bundle.kec)
if [ "$out" != "dep-ok" ]; then
  echo "unexpected bundle output: $out" >&2
  exit 1
fi
