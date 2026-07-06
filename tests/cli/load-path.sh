#!/bin/sh
# `load` resolves a relative path against the LOADING file's directory —
# the same dependency graph `kec build` bundles — with a CWD fallback when
# nothing exists at the file-relative candidate (repo-root-relative suites).
set -eu

kec=$1
case "$kec" in /*) ;; *) kec=$(pwd)/$kec ;; esac    # we cd around below
tmp=${TMPDIR:-/tmp}/kec-load-path-$$
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/app/lib" "$tmp/legacy"

cat > "$tmp/app/lib/inner.lsp" <<'LSP'
(defn inner-value () "inner-ok")
LSP

cat > "$tmp/app/dep.lsp" <<'LSP'
(load "lib/inner.lsp")
(defn dep-value () (string-append "dep+" (inner-value)))
LSP

cat > "$tmp/app/main.lsp" <<'LSP'
(load "dep.lsp")
(princ (dep-value)) (newline)
LSP

# 1. `kec run` from OUTSIDE the script's directory: sibling-relative loads
#    (and their nested loads) resolve against each loading file.
out=$(cd "$tmp" && "$kec" run app/main.lsp)
[ "$out" = "dep+inner-ok" ] || { echo "FAIL run: '$out'" >&2; exit 1; }

# 2. `kec build` of the same program bundles the same graph.
(cd "$tmp" && "$kec" build app/main.lsp -o bundle.kec) >/dev/null
out=$(cd "$tmp" && "$kec" run bundle.kec)
[ "$out" = "dep+inner-ok" ] || { echo "FAIL build: '$out'" >&2; exit 1; }

# 3. `require` resolves its path the same way.
cat > "$tmp/app/rmain.lsp" <<'LSP'
(require 'dep "dep.lsp")
(princ (dep-value)) (newline)
LSP
out=$(cd "$tmp" && "$kec" run app/rmain.lsp)
[ "$out" = "dep+inner-ok" ] || { echo "FAIL require: '$out'" >&2; exit 1; }

# 4. CWD fallback: nothing at the file-relative candidate, but the CWD has it.
cat > "$tmp/cwd-dep.lsp" <<'LSP'
(defn cwd-value () "cwd-ok")
LSP
cat > "$tmp/legacy/uses-cwd.lsp" <<'LSP'
(load "cwd-dep.lsp")
(princ (cwd-value)) (newline)
LSP
out=$(cd "$tmp" && "$kec" run legacy/uses-cwd.lsp)
[ "$out" = "cwd-ok" ] || { echo "FAIL cwd fallback: '$out'" >&2; exit 1; }

#    ... and `kec build` applies the same fallback (identical graphs always).
(cd "$tmp" && "$kec" build legacy/uses-cwd.lsp -o cwd-bundle.kec) >/dev/null
out=$(cd "$tmp" && "$kec" run cwd-bundle.kec)
[ "$out" = "cwd-ok" ] || { echo "FAIL build cwd fallback: '$out'" >&2; exit 1; }

# 5. Absolute load paths pass through; their nested relative loads still
#    resolve against the loaded file's directory.
cat > "$tmp/abs.lsp" <<LSP
(load "$tmp/app/dep.lsp")
(princ (dep-value)) (newline)
LSP
out=$(cd / && "$kec" run "$tmp/abs.lsp")
[ "$out" = "dep+inner-ok" ] || { echo "FAIL absolute: '$out'" >&2; exit 1; }

echo "load-path OK"
