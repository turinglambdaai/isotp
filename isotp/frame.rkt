#lang racket/base

;; ISO 15765-2 protocol data units: the four frame types SF / FF / CF / FC
;; and their codec, including the CAN FD escape encodings.
;;
;; Frames are decoded from and encoded to the payload bytes of one CAN
;; frame (CAN_DL bytes, i.e. everything after the identifier).  Addressing
;; prefixes (extended / mixed modes) are stripped by the caller before
;; decoding and re-added after encoding.
;;
;; In decoded FF frames the full message length is carried in the
;; `sequence-number` field (it is the only free integer slot); for CF frames
;; it is the 4-bit sequence number, as on the wire.

(require racket/contract
         racket/match
         "config.rkt")

(provide (contract-out
          (struct isotp-frame
            ((type symbol?)  ; 'sf 'ff 'cf 'fc
             (data (or/c #f bytes?))
             (flow-status (or/c #f symbol?)) ; 'cts 'wait 'overflow for FC
             (block-size (or/c #f (integer-in 0 255)))
             (stmin-us (or/c #f real?))
             (raw-stmin (or/c #f (integer-in 0 255)))
             (sequence-number (or/c #f exact-nonnegative-integer?)) ; CF: 0-15; FF: total length
             (escape? boolean?)
             (can-dl exact-nonnegative-integer?)))
          [bytes->isotp-frame
           (->* (bytes?) (exact-nonnegative-integer?) isotp-frame?)]
          [isotp-frame->bytes
           (->* (isotp-frame?)
                (#:fill exact-nonnegative-integer?
                 #:pad-byte (integer-in 0 255))
                bytes?)]
          [sf-frame (-> bytes? isotp-frame?)]
          [sf-frame/escape (-> bytes? isotp-frame?)]
          [ff-frame (-> (integer-in 1 4095) bytes? isotp-frame?)]
          [ff-frame/escape (-> (integer-in 4096 4294967295) bytes? isotp-frame?)]
          [cf-frame (-> (integer-in 0 15) bytes? isotp-frame?)]
          [fc-frame (-> (or/c 'cts 'wait 'overflow)
                        (integer-in 0 255)
                        (integer-in 0 900000)
                        isotp-frame?)]
          [stmin-byte->us (-> (integer-in 0 255) exact-nonnegative-integer?)]
          [stmin-us->byte (-> (integer-in 0 900000) (integer-in 0 255))]
          [pad-bytes (-> bytes? exact-nonnegative-integer? (integer-in 0 255) bytes?)]))

(struct isotp-frame
  (type data flow-status block-size stmin-us raw-stmin sequence-number escape? can-dl)
  #:transparent)

;; ---------------------------------------------------------------------------
;; STmin (ISO 15765-2 section 9.2.4.2)
;;
;; 0x00-0x7F : 0-127 ms;  0xF1-0xF9 : 100-900 us;  other values are reserved
;; and shall be treated as 0x7F (127 ms) by the receiving entity.

(define (stmin-byte->us b)
  (cond [(<= b #x7F) (* b 1000)]
        [(and (>= b #xF1) (<= b #xF9)) (* (- b #xF0) 100)]
        [else (* 127 1000)]))  ; reserved: treat as 127 ms

(define (stmin-us->byte us)
  (cond [(and (<= us 127000) (zero? (remainder us 1000))) (quotient us 1000)]
        [(and (<= 100 us 900) (zero? (remainder us 100))) (+ #xF0 (quotient us 100))]
        [else (error 'stmin-us->byte
                     "STmin ~a us is not encodable (use a multiple of 1 ms up to 127 ms, or 100-900 us in 100 us steps)"
                     us)]))

;; ---------------------------------------------------------------------------
;; Decoding

;; Trailing padding may make CAN_DL larger than the PCI requires, so every
;; length check here is a lower bound.

(define (pdu-error what expected got)
  (error 'bytes->isotp-frame
         "truncated ~a: need at least ~a payload byte(s) after the prefix, got ~a"
         what expected got))

(define (bytes->isotp-frame payload [prefix-size 0])
  (define can-dl (bytes-length payload))
  (when (< can-dl prefix-size)
    (error 'bytes->isotp-frame
           "CAN payload of ~a byte(s) is shorter than the ~a-byte addressing prefix"
           can-dl prefix-size))
  (define start prefix-size)
  (define datalen (- can-dl start))
  (when (zero? datalen)
    (error 'bytes->isotp-frame "empty CAN payload"))
  (define b0 (bytes-ref payload start))
  (define hnb (arithmetic-shift (bitwise-and b0 #xF0) -4))
  (define (slice from to) (subbytes payload from to))
  (case hnb
    [(0) ; Single Frame
     (define nibble (bitwise-and b0 #x0F))
     (cond
       [(not (zero? nibble))
        (unless (<= nibble 7)
          (error 'bytes->isotp-frame "single frame length nibble must be 1-7, got ~a" nibble))
        (when (< datalen (+ 1 nibble))
          (pdu-error "single frame" (+ 1 nibble) datalen))
        (isotp-frame 'sf (slice (+ start 1) (+ start 1 nibble)) #f #f #f #f #f #f can-dl)]
       [else
        (when (< datalen 2)
          (pdu-error "single frame with escape sequence" 2 datalen))
        (define len (bytes-ref payload (+ start 1)))
        (when (zero? len)
          (error 'bytes->isotp-frame "single frame declares 0 payload bytes"))
        (when (< datalen (+ 2 len))
          (pdu-error "single frame payload" (+ 2 len) datalen))
        (isotp-frame 'sf (slice (+ start 2) (+ start 2 len)) #f #f #f #f #f #t can-dl)])]
    [(1) ; First Frame
     (when (< datalen 2)
       (pdu-error "first frame" 2 datalen))
     (define len12
       (+ (arithmetic-shift (bitwise-and b0 #x0F) 8)
          (bytes-ref payload (+ start 1))))
     (cond
       [(not (zero? len12))
        (isotp-frame 'ff (slice (+ start 2) can-dl) #f #f #f #f len12 #f can-dl)]
       [else
        (when (< datalen 6)
          (pdu-error "first frame with escape sequence" 6 datalen))
        (define len
          (+ (* (bytes-ref payload (+ start 2)) 16777216)
             (* (bytes-ref payload (+ start 3)) 65536)
             (* (bytes-ref payload (+ start 4)) 256)
             (bytes-ref payload (+ start 5))))
        (isotp-frame 'ff (slice (+ start 6) can-dl) #f #f #f #f len #t can-dl)])]
    [(2) ; Consecutive Frame
     (isotp-frame 'cf (slice (+ start 1) can-dl) #f #f #f #f (bitwise-and b0 #x0F) #f can-dl)]
    [(3) ; Flow Control
     (when (< datalen 3)
       (pdu-error "flow control frame" 3 datalen))
     (define fs (bitwise-and b0 #x0F))
     (unless (<= fs 2)
       (error 'bytes->isotp-frame "unknown flow status ~a" fs))
     (define raw-stmin (bytes-ref payload (+ start 2)))
     (isotp-frame 'fc
                  #f
                  (list-ref '(cts wait overflow) fs)
                  (bytes-ref payload (+ start 1))
                  (stmin-byte->us raw-stmin)
                  raw-stmin
                  #f
                  #f
                  can-dl)]
    [else (error 'bytes->isotp-frame "unknown frame type nibble ~a" hnb)]))

;; ---------------------------------------------------------------------------
;; Encoding

;; PCI sizes, without the payload and without any addressing prefix.
(define (pci-size f)
  (case (isotp-frame-type f)
    [(sf) (if (isotp-frame-escape? f) 2 1)]
    [(ff) (if (isotp-frame-escape? f) 6 2)]
    [(cf) 1]
    [(fc) 3]))

(define (isotp-frame->bytes f #:fill [fill 0] #:pad-byte [pad-byte 0])
  (define data (isotp-frame-data f))
  (define dl (if (bytes? data) (bytes-length data) 0))
  (define header
    (case (isotp-frame-type f)
      [(sf) (if (isotp-frame-escape? f)
                (bytes #x00 dl)
                (bytes dl))]
      [(ff) (define total (isotp-frame-sequence-number f))
            (if (isotp-frame-escape? f)
                (bytes #x10
                       #x00
                       (bitwise-and (arithmetic-shift total -24) #xFF)
                       (bitwise-and (arithmetic-shift total -16) #xFF)
                       (bitwise-and (arithmetic-shift total -8) #xFF)
                       (bitwise-and total #xFF))
                (bytes (bitwise-ior #x10 (bitwise-and (arithmetic-shift total -8) #x0F))
                       (bitwise-and total #xFF)))]
      [(cf) (bytes (bitwise-ior #x20 (isotp-frame-sequence-number f)))]
      [(fc) (bytes (bitwise-ior #x30
                                (case (isotp-frame-flow-status f)
                                  [(cts) 0]
                                  [(wait) 1]
                                  [(overflow) 2]))
                   (isotp-frame-block-size f)
                   (stmin-us->byte (isotp-frame-stmin-us f)))]))
  (define natural (+ (bytes-length header) (if (bytes? data) dl 0)))
  (define total-len (max fill natural))
  (define out (make-bytes total-len pad-byte))
  (bytes-copy! out 0 header)
  (when (bytes? data)
    (bytes-copy! out (bytes-length header) data))
  out)

;; Pad `bs` up to `fill` bytes with `pad-byte`; returns `bs` unchanged when it
;; already fills the requested length.
(define (pad-bytes bs fill pad-byte)
  (if (<= fill (bytes-length bs))
      bs
      (let ([out (make-bytes fill pad-byte)])
        (bytes-copy! out 0 bs)
        out)))

;; ---------------------------------------------------------------------------
;; Frame constructors

(define (check-sf-length data escape?)
  (define len (bytes-length data))
  (unless (< 0 len (if escape? 63 8))
    (error (if escape? 'sf-frame/escape 'sf-frame)
           "~a single frames carry 1-~a payload bytes, got ~a"
           (if escape? "escaped" "plain") (if escape? 62 7) len)))

(define (sf-frame data)
  (check-sf-length data #f)
  (isotp-frame 'sf data #f #f #f #f #f #f (bytes-length data)))

(define (sf-frame/escape data)
  (check-sf-length data #t)
  (isotp-frame 'sf data #f #f #f #f #f #t (bytes-length data)))

(define (ff-frame total data)
  (isotp-frame 'ff data #f #f #f #f total #f (bytes-length data)))

(define (ff-frame/escape total data)
  (isotp-frame 'ff data #f #f #f #f total #t (bytes-length data)))

(define (cf-frame sn data)
  (isotp-frame 'cf data #f #f #f #f sn #f (bytes-length data)))

(define (fc-frame flow-status block-size stmin-us-value)
  (isotp-frame 'fc #f flow-status block-size stmin-us-value (stmin-us->byte stmin-us-value) #f #f 0))
