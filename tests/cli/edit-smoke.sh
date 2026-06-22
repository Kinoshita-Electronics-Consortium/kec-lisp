#!/bin/sh
# Smoke-test `kec edit` end-to-end: open a file in the structural editor, drive
# the :nemacs-nav keymap over piped keystrokes (descend, delete, save, quit), and
# confirm the structural edit was serialized back. Usage: edit-smoke.sh <kec>
KEC="$1"
if [ -z "$KEC" ]; then echo "usage: edit-smoke.sh <kec>"; exit 2; fi

tmp="${TMPDIR:-/tmp}/kec_edit_smoke_$$.lsp"

# --- structural delete: l = descend onto `a`, d = delete, W = save, q = quit ---
printf '(a b c)\n' > "$tmp"
printf 'ldWq' | "$KEC" edit "$tmp" >/dev/null 2>&1
result=$(cat "$tmp")
case "$result" in
  *"(b c)"*) ;;
  *) echo "FAIL: expected (b c), got: [$result]"; rm -f "$tmp"; exit 1 ;;
esac
case "$result" in
  *"(a b c)"*) echo "FAIL: 'a' was not deleted: [$result]"; rm -f "$tmp"; exit 1 ;;
esac

# --- literal insert: l descend onto `a`, i enter literal, type `b`, Enter
# commit, W save, q quit  ->  (a b c) ---
printf '(a c)\n' > "$tmp"
printf 'lib\nWq' | "$KEC" edit "$tmp" >/dev/null 2>&1
result=$(cat "$tmp")
rm -f "$tmp"
case "$result" in
  *"(a b c)"*) ;;
  *) echo "FAIL: literal insert expected (a b c), got: [$result]"; exit 1 ;;
esac
exit 0
