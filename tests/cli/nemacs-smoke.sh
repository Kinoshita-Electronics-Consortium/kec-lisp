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
case "$result" in
  a) ;;
  *) echo "FAIL: backspace expected 'a', got: [$result]"; rm -f "$tmp"; exit 1 ;;
esac

# A second temp for byte-exact expected content. cmp catches differences that
# $(cat ...) hides — command substitution strips trailing newlines, so the
# accretion/truncation regressions below are invisible to a string compare.
exp="${TMPDIR:-/tmp}/kec_nemacs_exp_$$"

# --- no trailing-newline accretion: open a file ending in '\n', save+exit with
#     NO edits; the bytes must be byte-identical. Regression: save appended an
#     extra '\n' every time, so each save grew the file by a blank line. ---
printf 'abc\n' > "$tmp"
printf '\030\023\030\003' | "$KEC" nemacs "$tmp" >/dev/null 2>&1
printf 'abc\n' > "$exp"
if ! cmp -s "$tmp" "$exp"; then
  echo "FAIL: save accreted bytes; expected 'abc\\n' byte-exact, got:"; od -c "$tmp"
  rm -f "$tmp" "$exp"; exit 1
fi

# --- large file (>64 KB) round-trips byte-exact. Covers two fixes: save no
#     longer truncates at a 64 KB C buffer (it routes through write-file), and
#     opening is now O(n) (linear %split-lines) so this completes instantly
#     instead of hanging ~20s on the old O(n^2) splitter. ---
{ head -c 70000 /dev/zero | tr '\0' 'a'; printf '\n'; } > "$tmp"
cp "$tmp" "$exp"
printf '\030\023\030\003' | "$KEC" nemacs "$tmp" >/dev/null 2>&1
if ! cmp -s "$tmp" "$exp"; then
  echo "FAIL: large-file save not byte-exact; expected $(wc -c < "$exp") bytes, got $(wc -c < "$tmp")"
  rm -f "$tmp" "$exp"; exit 1
fi

# --- TAB indents with soft spaces (to the next width-2 stop): TAB then 'x' on an
#     empty buffer yields "  x". Exercises the host "TAB" -> binding dispatch. ---
printf '' > "$tmp"
printf '\011x\030\023\030\003' | "$KEC" nemacs "$tmp" >/dev/null 2>&1
printf '  x' > "$exp"
if ! cmp -s "$tmp" "$exp"; then
  echo "FAIL: TAB soft-indent expected '  x', got: [$(cat "$tmp")]"
  rm -f "$tmp" "$exp"; exit 1
fi

# --- quit guard, save path: edit then C-x C-c answered 'y' SAVES before exit. ---
printf 'orig\n' > "$tmp"
printf 'X\030\003y' | "$KEC" nemacs "$tmp" >/dev/null 2>&1
printf 'Xorig\n' > "$exp"
if ! cmp -s "$tmp" "$exp"; then
  echo "FAIL: quit+save expected 'Xorig\\n', got: [$(cat "$tmp")]"
  rm -f "$tmp" "$exp"; exit 1
fi

# --- quit guard, discard path: edit then C-x C-c answered 'n' DROPS edits. ---
printf 'orig\n' > "$tmp"
printf 'X\030\003n' | "$KEC" nemacs "$tmp" >/dev/null 2>&1
printf 'orig\n' > "$exp"
if ! cmp -s "$tmp" "$exp"; then
  echo "FAIL: quit+discard expected 'orig\\n' (edits dropped), got: [$(cat "$tmp")]"
  rm -f "$tmp" "$exp"; exit 1
fi

rm -f "$tmp" "$exp"
exit 0
