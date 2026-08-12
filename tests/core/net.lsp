;; KEC Lisp — TCP primitive conformance (host/net.c).
;;
;; HERMETIC. Every socket here is a loopback socket this file created; the
;; suite never touches the outside network, never resolves a public name, and
;; never needs a proxy running. Both peers live in this one process: a client
;; connect() completes as soon as the kernel queues it on the listener's
;; backlog, before accept() runs, so a single thread can drive both ends as
;; long as payloads stay well inside the socket buffers (they do; the largest
;; below is a few hundred bytes).
;;
;; These primitives are FULL-profile only. The SANDBOX half of the contract,
;; that tcp-* and sleep are simply absent there, needs a second context, which
;; .lsp cannot open, so it lives in tests/c/test_net.c.

;; Bind an ephemeral loopback port and read back the number the kernel picked.
;; No hard-coded port, so a stray process (or a previous run) holding one cannot
;; make the suite flake.
(defn %net-listen ()
  (let srv (tcp-listen 0))
  (cons srv (tcp-port srv)))

;; A connected pair: (listener client server-side-connection port).
(defn %net-pair ()
  (let lp (%net-listen))
  (let srv (car lp))
  (let cli (tcp-connect "127.0.0.1" (cdr lp) 2000))
  (let con (tcp-accept srv 2000))
  (if (nil? con) (raise "net test: accept timed out on loopback") nil)
  (list srv cli con (cdr lp)))

(defn %net-drop (p)
  (tcp-close (nth p 1))
  (tcp-close (nth p 2))
  (tcp-close (nth p 0)))

;; --- the primitives are present -----------------------------------------

(deftest "net/primitives-bound"
  (check (bound? 'tcp-connect))
  (check (bound? 'tcp-send))
  (check (bound? 'tcp-recv))
  (check (bound? 'tcp-close))
  (check (bound? 'tcp-listen))
  (check (bound? 'tcp-accept))
  (check (bound? 'sleep)))

;; --- listen / accept / connect ------------------------------------------

(deftest "net/listen-accept-connect"
  (let p (%net-pair))
  (check (is (type-of (nth p 0)) ':ptr))
  (check (is (type-of (nth p 1)) ':ptr))
  (check (is (type-of (nth p 2)) ':ptr))
  (%net-drop p))

(deftest "net/accept-times-out-to-nil"
  ;; A timeout is not an error: nobody connected, so accept yields nil.
  (let lp (%net-listen))
  (check (nil? (tcp-accept (car lp) 50)))
  (tcp-close (car lp)))

(deftest "net/connect-refused-raises"
  ;; Bind a port, release it, then connect: nothing is listening, so the
  ;; connect fails, and a transport failure raises rather than returning nil.
  (let lp (%net-listen))
  (let port (cdr lp))
  (tcp-close (car lp))
  (let r (try (fn () (tcp-connect "127.0.0.1" port 1000))))
  (check (error? r))
  ;; the message names the host, the port, and the OS reason
  (check (string-contains? (error-message r) "127.0.0.1"))
  (check (string-contains? (error-message r) (number->string port)))
  (check (string-prefix? (error-message r) "tcp-connect:")))

(deftest "net/connect-rejects-bad-arguments"
  (check-err (tcp-connect "127.0.0.1" 0))        ; port 0 is not connectable
  (check-err (tcp-connect "127.0.0.1" 70000))
  (check-err (tcp-connect "127.0.0.1" 8080 -1))  ; negative timeout
  (check-err (tcp-listen -1))
  (check-err (tcp-listen 70000)))

;; --- send / recv --------------------------------------------------------

(deftest "net/round-trip-payload"
  (let p (%net-pair))
  (let cli (nth p 1))
  (let con (nth p 2))
  (check (is (tcp-send cli "KN-86 DECKLINE") 14))    ; returns bytes written
  (check (is (tcp-recv con 64) "KN-86 DECKLINE"))
  ;; and back the other way
  (check (is (tcp-send con "ACK") 3))
  (check (is (tcp-recv cli 64) "ACK"))
  (%net-drop p))

(deftest "net/recv-is-bounded-by-max-bytes"
  (let p (%net-pair))
  (tcp-send (nth p 1) "abcdefghij")
  ;; one read yields at most max-bytes; the rest stays queued
  (let first (tcp-recv (nth p 2) 4))
  (check (is (string-length first) 4))
  (check (is first "abcd"))
  ;; drain the remainder (possibly across several reads)
  (let rest "")
  (while (< (string-length rest) 6)
    (set rest (str rest (tcp-recv (nth p 2) 64))))
  (check (is rest "efghij"))
  (%net-drop p))

(deftest "net/recv-returns-nil-at-clean-eof"
  (let p (%net-pair))
  (tcp-send (nth p 1) "bye")
  (tcp-close (nth p 1))
  (check (is (tcp-recv (nth p 2) 64) "bye"))
  (check (nil? (tcp-recv (nth p 2) 64)))       ; orderly shutdown -> nil
  (check (nil? (tcp-recv (nth p 2) 64)))       ; ... and stays nil
  (tcp-close (nth p 2))
  (tcp-close (nth p 0)))

;; High bytes survive the round trip. An embedded NUL does not, because KEC
;; strings are NUL-terminated, which is exactly why the contract is capped at
;; text and why binary payloads need the peer protocol's own framing. This test
;; pins
;; both halves of that statement.
(deftest "net/high-bytes-survive"
  (let p (%net-pair))
  (let payload (str (char->string 200) (char->string 255) (char->string 128) "z"))
  (check (is (string-length payload) 4))
  (tcp-send (nth p 1) payload)
  (let got (tcp-recv (nth p 2) 64))
  (check (is (string-length got) 4))
  (check (is (string-ref got 0) 200))
  (check (is (string-ref got 1) 255))
  (check (is (string-ref got 2) 128))
  (check (is got payload))
  (%net-drop p))

;; A blob is sent verbatim, matching write-file, so the SEND direction is
;; binary-safe even where recv is not.
(deftest "net/send-accepts-a-blob"
  (let p (%net-pair))
  (let b (make-blob 3))
  (blob-set! b 0 65)
  (blob-set! b 1 66)
  (blob-set! b 2 67)
  (check (is (tcp-send (nth p 1) b) 3))
  (check (is (tcp-recv (nth p 2) 64) "ABC"))
  (%net-drop p))

(deftest "net/send-stringifies-non-strings"
  (let p (%net-pair))
  (tcp-send (nth p 1) 42)
  (check (is (tcp-recv (nth p 2) 64) "42"))
  (%net-drop p))

(deftest "net/recv-rejects-bad-max-bytes"
  (let p (%net-pair))
  (check-err (tcp-recv (nth p 2) 0))
  (check-err (tcp-recv (nth p 2) -5))
  (check-err (tcp-recv (nth p 2) 99999999))     ; past the 1 MiB per-call cap
  (%net-drop p))

;; --- close --------------------------------------------------------------

(deftest "net/close-is-idempotent"
  (let p (%net-pair))
  (check (nil? (tcp-close (nth p 1))))
  (check (nil? (tcp-close (nth p 1))))          ; closing twice is not an error
  (check (nil? (tcp-close (nth p 1))))
  (tcp-close (nth p 2))
  (tcp-close (nth p 0)))

(deftest "net/operations-on-a-closed-socket-raise"
  (let p (%net-pair))
  (tcp-close (nth p 1))
  (check-err (tcp-send (nth p 1) "x"))
  (check-err (tcp-recv (nth p 1) 16))
  (check-err (tcp-accept (nth p 1) 10))
  (tcp-close (nth p 2))
  (tcp-close (nth p 0)))

(deftest "net/handles-are-type-checked"
  (check-err (tcp-send "not-a-socket" "x"))
  (check-err (tcp-recv 7 16))
  (check-err (tcp-close nil))
  (check-err (tcp-accept (make-vector 2 0) 10)))

;; Port 0 binds an ephemeral port, useful here because it never collides.
;; 300 open/close cycles is well past a typical 256-descriptor soft limit, so
;; a close that failed to release its descriptor would fail this outright.
;; (The other half, that a handle DROPPED without tcp-close is closed by the
;; type's finalizer, is not observable from Lisp and lives in
;; tests/c/test_net.c.)
(deftest "net/explicit-close-releases-descriptors"
  (let i 0)
  (let ok 1)
  (while (< i 300)
    (let r (try (fn () (tcp-close (tcp-listen 0)))))
    (if (error? r) (do (set ok nil) (set i 300)) (set i (+ i 1))))
  (check ok))

;; --- sleep --------------------------------------------------------------

(deftest "sleep/waits-at-sub-second-resolution"
  (let t0 (now))
  (sleep 0.12)
  (let elapsed (- (now) t0))
  (check (< 0.1 elapsed))
  (check (< elapsed 3)))          ; generous: a loaded CI box still passes

(deftest "sleep/zero-and-bad-arguments"
  (check (nil? (sleep 0)))        ; returns nil
  (check-err (sleep -1))
  (check-err (sleep (/ 1 0))))    ; non-finite

;; --- tcp-port -----------------------------------------------------------

(deftest "net/tcp-port-reads-back-the-bound-port"
  ;; Port 0 asks the kernel for an ephemeral port; tcp-port is how a caller
  ;; learns which one, so a test never has to guess at a free number.
  (let srv (tcp-listen 0))
  (let port (tcp-port srv))
  (check (number? port))
  (check (< 0 port))
  (check (<= port 65535))
  ;; the number is real: connecting to it reaches this listener
  (let cli (tcp-connect "127.0.0.1" port 2000))
  (let con (tcp-accept srv 2000))
  (check (not (nil? con)))
  ;; a connected socket reports its own local (ephemeral) port, which is a
  ;; different one from the listener's
  (let local (tcp-port cli))
  (check (number? local))
  (check (< 0 local))
  (check (not (is local port)))
  ;; and the accepted end shares the listener's port
  (check (is (tcp-port con) port))
  (tcp-close cli) (tcp-close con) (tcp-close srv))

(deftest "net/tcp-port-rejects-bad-handles"
  (check-err (tcp-port "not-a-socket"))
  (check-err (tcp-port nil))
  (let srv (tcp-listen 0))
  (tcp-close srv)
  (check-err (tcp-port srv)))          ; closed handle

;; --- TLS ----------------------------------------------------------------
;;
;; The handshake itself needs a peer with a certificate, so the parts that can
;; run with no network at all live here and the certificate-verification
;; contract lives in tests/cli/tls-verify.sh (a self-signed cert on loopback:
;; refused untrusted, accepted once trusted, refused for a name it lacks).

(deftest "tls/primitive-bound"
  (check (bound? 'tls-connect)))

(deftest "tls/rejects-bad-arguments"
  (check-err (tls-connect "127.0.0.1" 0))
  (check-err (tls-connect "127.0.0.1" 70000))
  (check-err (tls-connect "127.0.0.1" 443 -1)))

(deftest "tls/refused-connection-raises"
  ;; Same transport failure as tcp-connect, named for the primitive that
  ;; produced it, so a connect failure is never mistaken for a TLS failure.
  (let lp (%net-listen))
  (let port (cdr lp))
  (tcp-close (car lp))
  (let r (try (fn () (tls-connect "127.0.0.1" port 1000))))
  (check (error? r))
  (check (string-prefix? (error-message r) "tls-connect:"))
  (check (string-contains? (error-message r) (number->string port))))

;; A plaintext peer must NOT be tolerated. If tls-connect quietly fell back to
;; cleartext when the handshake failed, every guarantee above would be void and
;; nothing else in the suite would notice.
(deftest "tls/will-not-talk-to-a-plaintext-peer"
  (let lp (%net-listen))
  (let srv (car lp))
  (let r (try (fn ()
    (do
      (let c (tls-connect "127.0.0.1" (cdr lp) 1000))
      (tcp-close c)))))
  (check (error? r))
  (check (string-prefix? (error-message r) "tls-connect:"))
  (tcp-close srv))
