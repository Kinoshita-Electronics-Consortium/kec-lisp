;; The client half of tests/cli/http-e2e.sh: one full http-request against the
;; canned server in http-server.lsp, printing what came back in a shape the
;; shell can grep.
;;
;;   kec run tests/cli/http-client.lsp PORT

(load "examples/http/http.lsp")

(let port (string->number (nth (args) 1)))
(if (nil? port) (do (princ "usage: http-client.lsp PORT") (newline) (exit 2)) nil)

(let url (str "http://127.0.0.1:" port "/grandexchange/history/copper_ore?size=3"))
(let headers '(("Host" . "api.artifactsmmo.com")))

;; The server may still be binding its port. Retry the whole request briefly:
;; a refused connection raises, which is the contract being relied on here.
(let res nil)
(let tries 0)
(while (and (nil? res) (< tries 60))
  (let r (try (fn () (http-get url headers))))
  (if (error? r) (sleep 0.05) (set res r))
  (set tries (+ tries 1)))

(if (nil? res) (do (princ "client: server never answered") (newline) (exit 1)) nil)

;; The body is the JSON array the server echoed: (request-line host).
(let echoed (json-parse (http-body res)))
(princ "status=") (princ (http-status res)) (newline)
(princ "line=") (princ (nth echoed 0)) (newline)
(princ "host=") (princ (nth echoed 1)) (newline)
