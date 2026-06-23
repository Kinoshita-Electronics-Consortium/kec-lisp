#!/bin/sh
# Smoke-test `kec nemacs` end-to-end: open a file in the knEmacs structural editor,
# drive the Emacs key bindings over piped keystrokes (sexp motion, kill, save,
# exit), and confirm the structural edit was serialized back. Usage: <kec>
#
# Chord bytes used below:
#   C-M-d down-list  = ESC C-d  = \033\004
#   C-M-k kill-sexp  = ESC C-k  = \033\013
#   C-x C-s save     = \030\023
#   C-x C-c exit     = \030\003
KEC="$1"
if [ -z "$KEC" ]; then echo "usage: nemacs-smoke.sh <kec>"; exit 2; fi

tmp="${TMPDIR:-/tmp}/kec_nemacs_smoke_$$.lsp"

# --- structural kill: C-M-d descend onto `a`, C-M-k kill it, C-x C-s, C-x C-c ---
printf '(a b c)\n' > "$tmp"
printf '\033\004\033\013\030\023\030\003' | "$KEC" nemacs "$tmp" >/dev/null 2>&1
result=$(cat "$tmp")
case "$result" in
  *"(b c)"*) ;;
  *) echo "FAIL: expected (b c), got: [$result]"; rm -f "$tmp"; exit 1 ;;
esac
case "$result" in
  *"(a b c)"*) echo "FAIL: 'a' was not killed: [$result]"; rm -f "$tmp"; exit 1 ;;
esac

# --- self-insert: C-M-d descend onto `a`, type `b` (self-insert), RET commit,
# C-x C-s save, C-x C-c exit  ->  (a b c) ---
printf '(a c)\n' > "$tmp"
printf '\033\004b\n\030\023\030\003' | "$KEC" nemacs "$tmp" >/dev/null 2>&1
result=$(cat "$tmp")
rm -f "$tmp"
case "$result" in
  *"(a b c)"*) ;;
  *) echo "FAIL: self-insert expected (a b c), got: [$result]"; exit 1 ;;
esac
exit 0
