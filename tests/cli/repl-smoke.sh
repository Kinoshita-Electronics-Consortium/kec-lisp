#!/bin/sh
# Smoke-test the `kec repl` strong REPL end-to-end: it loads the embedded
# editor/REPL tier, drives the REPL engine over piped input, and prints the
# formatted result of each line. Usage: repl-smoke.sh <path-to-kec>
set -e
KEC="$1"
if [ -z "$KEC" ]; then echo "usage: repl-smoke.sh <kec>"; exit 2; fi

out=$(printf '(+ 2 3)\n(list 1 2 3)\n(car 5)\n(* 4 5)\n:q\n' | "$KEC" repl)

echo "$out" | grep -q '^5$'        || { echo "FAIL: missing '5'";        echo "$out"; exit 1; }
echo "$out" | grep -q '^(1 2 3)$'  || { echo "FAIL: missing '(1 2 3)'";  echo "$out"; exit 1; }
echo "$out" | grep -q '^error:'    || { echo "FAIL: error not survived"; echo "$out"; exit 1; }
echo "$out" | grep -q '^20$'       || { echo "FAIL: loop died after error"; echo "$out"; exit 1; }
exit 0
