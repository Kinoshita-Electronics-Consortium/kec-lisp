;; KEC Core — bitwise host primitives (ADR-0001 D).
;; Decimal literals throughout (the reader's hex support via strtod is not
;; portable). 32-bit two's-complement semantics; bit-shr is a LOGICAL shift.

(deftest "bitwise/and-or-xor"
  (check (is (bit-and 12 10) 8))     ; 1100 & 1010 = 1000
  (check (is (bit-or 12 10) 14))     ; 1100 | 1010 = 1110
  (check (is (bit-xor 12 10) 6)))    ; 1100 ^ 1010 = 0110

(deftest "bitwise/not"
  (check (is (bit-not 0) -1))        ; ones complement of 0
  (check (is (bit-not -1) 0)))

(deftest "bitwise/shifts"
  (check (is (bit-shl 1 4) 16))      ; 1 << 4
  (check (is (bit-shr 256 4) 16))    ; 256 >> 4
  (check (is (bit-shl 5 0) 5))       ; shift by 0 is identity
  (check (is (bit-shr 5 0) 5)))

(deftest "bitwise/negative-operands-twos-complement"
  ;; A negative fe_Number casts to its two's-complement bit pattern.
  (check (is (bit-and -1 255) 255))  ; low byte of all-ones mask
  (check (is (bit-and -1 -1) -1)))

(deftest "bitwise/logical-shr-zero-fills"
  ;; -1 is 0xFFFFFFFF; a logical >>28 leaves the top nibble = 15, not -1.
  (check (is (bit-shr -1 28) 15)))
