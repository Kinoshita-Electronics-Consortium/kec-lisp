#!/bin/sh
# Idle-timer end-to-end inside `kec nemacs`. Arm a repeating timer (via the
# KN86_NEMACS_INIT hook) that appends '.' at point each tick, then hold stdin
# IDLE for a beat so the editor's poll() times out and fires the timer several
# times between keystrokes — proving animation/idle work runs INSIDE knEmacs,
# no interactive TTY required. Usage: idle-timer-smoke.sh <path-to-kec>
set -e
KEC="$1"
if [ -z "$KEC" ]; then echo "usage: idle-timer-smoke.sh <kec>"; exit 2; fi
tmp="${TMPDIR:-/tmp}/kec_idle_$$"

# Timer fires every 0.04s, inserting '.' at point.
KN86_NEMACS_INIT='(run-with-timer 0.04 0.04 (fn () (text-insert! *nemacs* ".")) (now))'
export KN86_NEMACS_INIT

printf '' > "$tmp"
# Type 'a', stay idle ~0.6s (timer fires many times -> "a......."), then save
# (C-x C-s = \030\023) and exit (C-x C-c = \030\003). The idle gap is what lets
# poll() time out; a gapless pipe would never exercise the timeout branch. We
# assert >=1 dot (a single fire already proves the claim) against a generous
# gap, so even a heavily-loaded CI runner that manages only one tick passes.
( printf 'a'; sleep 0.6; printf '\030\023\030\003' ) | "$KEC" nemacs "$tmp" >/dev/null 2>&1
unset KN86_NEMACS_INIT
result=$(cat "$tmp")

# Expect 'a' then at least one dot (a fired idle timer).
case "$result" in
  a.*) echo "OK: idle timer fired inside knEmacs -> [$result]" ;;
  *) echo "FAIL: idle timer did not fire; expected 'a' + dot(s), got: [$result]"
     rm -f "$tmp"; exit 1 ;;
esac

# A repeat-0 timer is a ONE-SHOT (KEC 0 is truthy — must not re-arm forever and
# spin). Arm it, idle, save+exit: exactly one dot, and the editor exits promptly
# (a busy-spin/hang would never reach the save). Result must be exactly "c.".
KN86_NEMACS_INIT='(run-with-timer 0.04 0 (fn () (text-insert! *nemacs* ".")) (now))'
export KN86_NEMACS_INIT
printf '' > "$tmp"
( printf 'c'; sleep 0.3; printf '\030\023\030\003' ) | "$KEC" nemacs "$tmp" >/dev/null 2>&1
unset KN86_NEMACS_INIT
if [ "$(cat "$tmp")" != "c." ]; then
  echo "FAIL: repeat-0 not a one-shot; expected 'c.', got: [$(cat "$tmp")]"; rm -f "$tmp"; exit 1
fi

# And the no-timer path is unaffected: without the hook, no dots appear.
printf '' > "$tmp"
( printf 'b'; sleep 0.2; printf '\030\023\030\003' ) | "$KEC" nemacs "$tmp" >/dev/null 2>&1
if [ "$(cat "$tmp")" != "b" ]; then
  echo "FAIL: no-timer path changed; expected 'b', got: [$(cat "$tmp")]"; rm -f "$tmp"; exit 1
fi

rm -f "$tmp"
exit 0
