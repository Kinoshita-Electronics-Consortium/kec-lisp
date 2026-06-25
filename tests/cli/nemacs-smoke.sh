#!/bin/sh
# Smoke-test `kec nemacs` end-to-end as a TEXT editor: open a file, drive real
# Emacs-style keystrokes over a pipe (self-insert, newline, cursor motion,
# Backspace, save, exit), and confirm the edited text was written back.
# Usage: nemacs-smoke.sh <kec>
#
# Chord bytes used below:
#   C-f forward-char        = \006
#   C-e move-end-of-line    = \005
#   DEL delete-backward     = \177
#   RET newline             = an actual newline in the printf string
#   C-x C-s save-buffer     = \030\023
#   C-x C-c exit-editor     = \030\003
KEC="$1"
if [ -z "$KEC" ]; then echo "usage: nemacs-smoke.sh <kec>"; exit 2; fi

tmp="${TMPDIR:-/tmp}/kec_nemacs_smoke_$$.lsp"

# --- self-insert + newline: type two lines into a scratch file, save, exit ---
printf '' > "$tmp"
printf 'hello\n(+ 1 2)\030\023\030\003' | "$KEC" nemacs "$tmp" >/dev/null 2>&1
result=$(cat "$tmp")
case "$result" in
  *"hello"*"(+ 1 2)"*) ;;
  *) echo "FAIL: self-insert expected 'hello' + '(+ 1 2)', got: [$result]"; rm -f "$tmp"; exit 1 ;;
esac

# --- cursor motion + mid-line insert: abcd, C-f C-f to col 2, insert X -> abXcd ---
printf 'abcd' > "$tmp"
printf '\006\006X\030\023\030\003' | "$KEC" nemacs "$tmp" >/dev/null 2>&1
result=$(cat "$tmp")
case "$result" in
  *"abXcd"*) ;;
  *) echo "FAIL: mid-line insert expected abXcd, got: [$result]"; rm -f "$tmp"; exit 1 ;;
esac

# --- Backspace: abc, C-e to end, DEL DEL -> a ---
printf 'abc' > "$tmp"
printf '\005\177\177\030\023\030\003' | "$KEC" nemacs "$tmp" >/dev/null 2>&1
result=$(cat "$tmp")
rm -f "$tmp"
case "$result" in
  a) ;;
  *) echo "FAIL: backspace expected 'a', got: [$result]"; exit 1 ;;
esac
exit 0
