;; KEC Core — strtool : string & char toolkit
;;
;; Pure Lisp over the host string primitives (string-ref returns a char code;
;; char->string takes a code; string-length / substring / string-append /
;; string-search exist). Case helpers, fixed-cell-grid layout (pad/repeat), and
;; the prefix/suffix/contains tests knEmacs and cart authoring reach for. Loads
;; after 60-str (which it builds on) and before 70-sort.

;; --- case ---------------------------------------------------------------

;; (char-upcase c) / (char-downcase c) — shift a–z/A–Z by 32; pass anything else
;; through unchanged. Operate on char codes (as string-ref returns).
(defn char-upcase (c)
  (if (and (<= 97 c) (<= c 122)) (- c 32) c))

(defn char-downcase (c)
  (if (and (<= 65 c) (<= c 90)) (+ c 32) c))

;; Map a char-transform over every character of s, rebuilding the string.
(defn %string-map-chars (f s)
  (let n (string-length s))
  (let out "")
  (let i 0)
  (while (< i n)
    (set out (string-append out (char->string (f (string-ref s i)))))
    (set i (+ i 1)))
  out)

(defn string-upcase (s)
  (%string-map-chars char-upcase s))

(defn string-downcase (s)
  (%string-map-chars char-downcase s))

;; --- layout (fixed-cell text grid) --------------------------------------

;; (string-repeat s n) — s concatenated n times; n<=0 yields "".
(defn string-repeat (s n)
  (let out "")
  (let i 0)
  (while (< i n)
    (set out (string-append out s))
    (set i (+ i 1)))
  out)

;; (string-concat xs) — concatenate a list of strings.
;;
;; The obvious spellings both break down on long lists: folding with `str` is
;; quadratic (every step copies the whole accumulator), while one
;; (apply str xs) pushes a GC root per argument (evallist conses each
;; evaluated argument), and a few hundred of those overflow the device's
;; 256-slot root stack. Collapsing in batches of 8 bounds both: O(n log n)
;; copying, never more than 8 roots at a time. Any code assembling a string
;; from many pieces (the JSON writer, an HTTP request line, a tokenizer) wants
;; this rather than a fold.
(defn string-concat (xs)
  (if (nil? xs)
      ""
      (do
        (while (cdr xs)
          (let out nil)
          (while xs
            (let batch nil)
            (let k 0)
            (while (and xs (< k 8))
              (set batch (cons (car xs) batch))
              (set xs (cdr xs))
              (set k (+ k 1)))
            (set out (cons (apply str (reverse batch)) out)))
          (set xs (reverse out)))
        ;; `str` on the survivor as well, so a one-element list of a non-string
        ;; still comes back stringified rather than passed through.
        (str (car xs)))))

;; (pad-left s width [pad]) — prepend copies of pad (default " ") until s reaches
;; width. No truncation: an s already >= width is returned unchanged.
(defn pad-left (s width . rest)
  (let pad (if rest (car rest) " "))
  (if (not (is (string-length pad) 1))
      (raise "pad-left: pad must be one character") nil)
  (let need (- width (string-length s)))
  (if (< 0 need)
      (string-append (string-repeat pad need) s)
      s))

;; (pad-right s width [pad]) — append copies of pad (default " ") until width.
;; No truncation.
(defn pad-right (s width . rest)
  (let pad (if rest (car rest) " "))
  (if (not (is (string-length pad) 1))
      (raise "pad-right: pad must be one character") nil)
  (let need (- width (string-length s)))
  (if (< 0 need)
      (string-append s (string-repeat pad need))
      s))

;; --- tests --------------------------------------------------------------

;; (string-prefix? s affix) — does s start with affix? Empty affix -> true; an
;; affix longer than s -> false. Compares the leading slice of s with substring.
(defn string-prefix? (s affix)
  (let alen (string-length affix))
  (if (< (string-length s) alen)
      nil
      (is (substring s 0 alen) affix)))

;; (string-suffix? s affix) — does s end with affix? Empty affix -> true; an
;; affix longer than s -> false.
(defn string-suffix? (s affix)
  (let slen (string-length s))
  (let alen (string-length affix))
  (if (< slen alen)
      nil
      (is (substring s (- slen alen) slen) affix)))

;; (string-contains? s needle) — is needle anywhere in s? Empty needle -> true
;; (string-search matches at 0). Built on host string-search (haystack needle).
(defn string-contains? (s needle)
  (not (nil? (string-search s needle))))
