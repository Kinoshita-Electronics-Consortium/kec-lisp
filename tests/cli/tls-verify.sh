#!/bin/sh
# The security property of tls-connect, tested hermetically: an untrusted
# certificate is REFUSED, and the same certificate is ACCEPTED once its issuer
# is trusted. Both halves matter. A client that accepts anything would pass a
# "does it connect" test while providing no security at all, and a client that
# refuses everything would look equally "safe" while being useless.
#
# Everything runs on loopback against a throwaway self-signed certificate, so
# there is no dependency on any outside host. Public bad-certificate services
# rate-limit, which makes them useless as a gate.
#
# Usage: tls-verify.sh <path-to-kec>
set -e
KEC="$1"
if [ -z "$KEC" ]; then echo "usage: tls-verify.sh <kec>"; exit 2; fi

# Prefer the OpenSSL the build linked against. macOS ships LibreSSL as
# `openssl`, whose s_server differs; the Homebrew one matches the library.
OSSL=""
for cand in "$OPENSSL_BIN" /opt/homebrew/opt/openssl@3/bin/openssl \
            /usr/local/opt/openssl@3/bin/openssl openssl; do
    if [ -n "$cand" ] && command -v "$cand" >/dev/null 2>&1; then OSSL="$cand"; break; fi
done
if [ -z "$OSSL" ]; then
    echo "SKIP: no openssl command available to act as the TLS peer"
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kec-tls.XXXXXX")
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# A self-signed certificate valid for 127.0.0.1. The SAN goes through a config
# file rather than -addext, which older/LibreSSL builds do not accept.
cat > "$WORK/req.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = localhost
[v3]
subjectAltName = IP:127.0.0.1
basicConstraints = critical, CA:TRUE
CNF

"$OSSL" req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
    -config "$WORK/req.cnf" -extensions v3 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1 \
    || { echo "SKIP: this openssl cannot generate the test certificate"; exit 0; }

# A free port, found with the primitives under test rather than guessed.
PORT=$("$KEC" eval '(do (let s (tcp-listen 0)) (let p (tcp-port s)) (tcp-close s) p)')
PORT=$(printf '%s' "$PORT" | tr -dc '0-9')
if [ -z "$PORT" ]; then echo "FAIL: could not obtain a free port"; exit 1; fi

"$OSSL" s_server -accept "$PORT" -naccept 20 -cert "$WORK/cert.pem" \
    -key "$WORK/key.pem" -quiet >/dev/null 2>&1 &
SERVER_PID=$!

# Wait for the listener (bounded: ~5s).
i=0
while [ "$i" -lt 100 ]; do
    if "$KEC" eval "(error? (try (fn () (tcp-close (tcp-connect \"127.0.0.1\" $PORT 500)))))" \
        2>/dev/null | grep -q '^nil$'; then
        break
    fi
    sleep 0.05
    i=$((i + 1))
done
if [ "$i" -ge 100 ]; then echo "FAIL: TLS test server never came up"; exit 1; fi

probe() {
    "$KEC" eval "(let r (try (fn () (tls-connect \"127.0.0.1\" $PORT 5000))))
                 (if (error? r) (str \"ERR \" (error-message r)) \"OK\")"
}

# 1. Untrusted issuer: the handshake must fail, and say so as a certificate
#    problem rather than a generic network error.
out=$(probe)
case "$out" in
    ERR*certificate\ rejected*) ;;
    *) echo "FAIL: an untrusted certificate was not rejected: $out"; exit 1 ;;
esac

# 2. Same certificate, now trusted through SSL_CERT_FILE: it must connect.
out=$(SSL_CERT_FILE="$WORK/cert.pem" probe)
case "$out" in
    OK) ;;
    *) echo "FAIL: a trusted certificate was not accepted: $out"; exit 1 ;;
esac

# 3. Trusted issuer, wrong name. The certificate carries an IP SAN for
#    127.0.0.1 and no DNS SAN, so reaching the SAME server through the name
#    `localhost` must fail on the name check. Asserting the REASON matters:
#    a refused connection is also "not OK", and an earlier version of this test
#    passed on exactly that, proving nothing.
out=$(SSL_CERT_FILE="$WORK/cert.pem" "$KEC" eval \
    "(let r (try (fn () (tls-connect \"localhost\" $PORT 5000))))
     (if (error? r) (str \"ERR \" (error-message r)) \"OK\")")
case "$out" in
    ERR*certificate\ rejected*hostname\ mismatch*) ;;
    *) echo "FAIL: expected a hostname-mismatch rejection, got: $out"; exit 1 ;;
esac

exit 0
