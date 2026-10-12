#lang racket/base

;; Test suite for the isotp package: frame codec golden vectors, STmin
;; tables, addressing identifiers, sender/receiver state machines, and a
;; loopback run of both machines against each other.

(require rackunit
         racket/string
         racket/match
         isotp/base
         isotp/config
         isotp/address
         isotp/frame
         isotp/tx
         isotp/rx)

;; rx-frame / rx-tick return four values; the tests prefer match-define on a
;; list, with _ wildcards.
(define (rx-f cfg st payload now)
  (define-values (a b c d) (rx-frame cfg st payload now))
  (list a b c d))

(define (rx-t cfg st now)
  (define-values (a b c d) (rx-tick cfg st now))
  (list a b c d))

;; ---------------------------------------------------------------------------
;; Frame codec

(test-case "single frame, plain form"
  (define f (sf-frame (bytes 1 2 3)))
  (check-equal? (isotp-frame->bytes f) (bytes #x03 1 2 3))
  (define d (bytes->isotp-frame (bytes #x03 1 2 3)))
  (check-equal? (isotp-frame-type d) 'sf)
  (check-equal? (isotp-frame-data d) (bytes 1 2 3))
  (check-equal? (isotp-frame-can-dl d) 4)
  (check-false (isotp-frame-escape? d)))

(test-case "single frame, trailing padding accepted on decode"
  (define d (bytes->isotp-frame (bytes #x02 1 2 0 0 0 0 0)))
  (check-equal? (isotp-frame-data d) (bytes 1 2))
  (check-equal? (isotp-frame-can-dl d) 8))

(test-case "single frame, CAN FD escape form"
  (define data (make-bytes 10 7))
  (define f (sf-frame/escape data))
  (check-equal? (isotp-frame->bytes f) (bytes-append (bytes #x00 10) data))
  (define d (bytes->isotp-frame (bytes-append (bytes #x00 10) data)))
  (check-true (isotp-frame-escape? d))
  (check-equal? (isotp-frame-data d) data))

(test-case "single frame, escape sequence with padding"
  (define d (bytes->isotp-frame (bytes #x00 2 1 2 #xAA #xAA)))
  (check-equal? (isotp-frame-data d) (bytes 1 2))
  (check-true (isotp-frame-escape? d)))

(test-case "single frame, seven payload bytes (classic maximum)"
  (define data (make-bytes 7 5))
  (check-equal? (isotp-frame->bytes (sf-frame data)) (bytes-append (bytes #x07) data)))

(test-case "single frame errors"
  (check-exn exn:fail? (lambda () (sf-frame (make-bytes 8))))
  (check-exn exn:fail? (lambda () (sf-frame/escape (make-bytes 63))))
  (check-exn exn:fail? (lambda () (sf-frame #"")))
  (check-exn exn:fail? (lambda () (bytes->isotp-frame (bytes #x08 1)))) ; nibble 8
  (check-exn exn:fail? (lambda () (bytes->isotp-frame (bytes #x05 1)))) ; truncated
  (check-exn exn:fail? (lambda () (bytes->isotp-frame (bytes #x00 0))))) ; length 0

(test-case "first frame, 12-bit length"
  (define f (ff-frame 256 (make-bytes 6 9)))
  (check-equal? (isotp-frame->bytes f) (bytes #x11 #x00 9 9 9 9 9 9))
  (define d (bytes->isotp-frame (bytes #x11 #x00 9 9 9 9 9 9)))
  (check-equal? (isotp-frame-type d) 'ff)
  (check-equal? (isotp-frame-sequence-number d) 256)
  (check-equal? (bytes-length (isotp-frame-data d)) 6))

(test-case "first frame, 4095 maximum"
  (define d (bytes->isotp-frame (bytes #x1F #xFF 1 2 3 4 5 6)))
  (check-equal? (isotp-frame-sequence-number d) 4095))

(test-case "first frame, escape form (32-bit length)"
  (define f (ff-frame/escape 4096 (make-bytes 6 1)))
  (check-equal? (isotp-frame->bytes f) (bytes #x10 #x00 #x00 #x00 #x10 #x00 1 1 1 1 1 1))
  (define d (bytes->isotp-frame (bytes #x10 #x00 #x00 #x00 #x10 #x00 1 1 1 1 1 1)))
  (check-true (isotp-frame-escape? d))
  (check-equal? (isotp-frame-sequence-number d) 4096)
  (check-exn exn:fail? (lambda () (ff-frame 4096 #""))))

(test-case "consecutive frame"
  (define f (cf-frame 5 (bytes #xAA #xBB)))
  (check-equal? (isotp-frame->bytes f) (bytes #x25 #xAA #xBB))
  (define d (bytes->isotp-frame (bytes #x25 #xAA #xBB)))
  (check-equal? (isotp-frame-sequence-number d) 5)
  (check-equal? (isotp-frame-data d) (bytes #xAA #xBB)))

(test-case "flow control"
  (define f (fc-frame 'cts 8 32000))
  (check-equal? (isotp-frame->bytes f) (bytes #x30 #x08 #x20))
  (check-equal? (isotp-frame->bytes (fc-frame 'wait 0 0)) (bytes #x31 #x00 #x00))
  (check-equal? (isotp-frame->bytes (fc-frame 'overflow 0 0)) (bytes #x32 #x00 #x00))
  (define d (bytes->isotp-frame (bytes #x30 #x08 #x20 0 0 0 0 0)))
  (check-equal? (isotp-frame-type d) 'fc)
  (check-equal? (isotp-frame-flow-status d) 'cts)
  (check-equal? (isotp-frame-block-size d) 8)
  (check-equal? (isotp-frame-stmin-us d) 32000)
  (check-exn exn:fail? (lambda () (bytes->isotp-frame (bytes #x33 0 0))))) ; unknown FS

(test-case "STmin decoding (reserved values are 127 ms per ISO 15765-2)"
  (check-equal? (stmin-byte->us #x00) 0)
  (check-equal? (stmin-byte->us #x01) 1000)
  (check-equal? (stmin-byte->us #x7F) 127000)
  (check-equal? (stmin-byte->us #x80) 127000)  ; reserved
  (check-equal? (stmin-byte->us #xF0) 127000)  ; reserved
  (check-equal? (stmin-byte->us #xF1) 100)
  (check-equal? (stmin-byte->us #xF9) 900)
  (check-equal? (stmin-byte->us #xFA) 127000)  ; reserved
  (check-equal? (stmin-byte->us #xFF) 127000)) ; reserved

(test-case "STmin encoding"
  (check-equal? (stmin-us->byte 0) #x00)
  (check-equal? (stmin-us->byte 1000) #x01)
  (check-equal? (stmin-us->byte 127000) #x7F)
  (check-equal? (stmin-us->byte 100) #xF1)
  (check-equal? (stmin-us->byte 900) #xF9)
  (check-exn exn:fail? (lambda () (stmin-us->byte 150)))   ; not a ms multiple
  (check-exn exn:fail? (lambda () (stmin-us->byte 150000)))) ; > 127 ms, not us

(test-case "padding"
  (check-equal? (isotp-frame->bytes (sf-frame (bytes 1 2)) #:fill 8 #:pad-byte #xAA)
                (bytes #x02 1 2 #xAA #xAA #xAA #xAA #xAA))
  (check-equal? (isotp-frame->bytes (cf-frame 1 (bytes 1)) #:fill 8 #:pad-byte #x55)
                (bytes #x21 1 #x55 #x55 #x55 #x55 #x55 #x55)))

;; ---------------------------------------------------------------------------
;; Addressing

(test-case "fixed 29-bit addressing identifiers"
  (define cfg (make-isotp-config #:addressing 'normal-fixed-29
                                 #:target-address #x10 #:source-address #xF1))
  (check-equal? (isotp-tx-id cfg) #x18DA10F1)
  (check-equal? (isotp-rx-id cfg) #x18DAF110)
  (check-equal? (isotp-tx-id cfg #t) #x18DB10F1)
  (check-equal? (isotp-rx-id cfg #t) #x18DBF110))

(test-case "functional request id (OBD-style)"
  (define cfg (make-isotp-config #:addressing 'normal-fixed-29
                                 #:target-address #x33 #:source-address #xF1))
  (check-equal? (isotp-tx-id cfg #t) #x18DB33F1))

(test-case "custom fixed-addressing prefix"
  (define cfg (make-isotp-config #:addressing 'mixed-29
                                 #:target-address #x01 #:source-address #x02
                                 #:address-extension #x99
                                 #:physical-id #x1CCC0000))
  (check-equal? (isotp-tx-id cfg) #x1CCC0102))

(test-case "normal and extended addressing identifiers"
  (define n (make-isotp-config #:addressing 'normal-11 #:tx-id #x7E0 #:rx-id #x7E8))
  (check-equal? (isotp-tx-id n) #x7E0)
  (check-equal? (isotp-rx-id n) #x7E8)
  (define e (make-isotp-config #:addressing 'extended-11 #:tx-id #x123 #:rx-id #x456
                               #:target-address #x10 #:source-address #xF1))
  (check-equal? (isotp-tx-id e) #x123))

(test-case "configuration validation"
  (check-exn exn:fail? (lambda () (make-isotp-config #:frame-size 10)))
  (check-exn exn:fail? (lambda () (make-isotp-config #:stmin-ms 5 #:stmin-us 500)))
  (check-exn exn:fail? (lambda () (make-isotp-config #:addressing 'normal-fixed-29)))
  (check-exn exn:fail? (lambda () (make-isotp-config #:addressing 'normal-fixed-29 #:tx-id 1)))
  (check-exn exn:fail? (lambda () (make-isotp-config #:addressing 'mixed-11 #:tx-id 1 #:rx-id 2)))
  (check-exn exn:fail? (lambda () (make-isotp-config #:tx-id #x800)))
  (check-exn exn:fail? (lambda () (make-isotp-config #:addressing 'normal-29 #:tx-id #x20000000 #:rx-id 1)))
  (check-exn exn:fail? (lambda () (make-isotp-config #:max-payload 5000)))) ; classic limit

;; ---------------------------------------------------------------------------
;; Sender state machine

(define (due-bytes frames) (map due-frame-bytes frames))

(test-case "tx: single frame completes immediately"
  (define cfg (make-isotp-config))
  (define-values (st frames) (start-tx cfg (bytes 1 2 3) 0))
  (check-equal? (tx-state-phase st) 'done)
  (check-equal? (due-bytes frames) (list (bytes #x03 1 2 3))))

(test-case "tx: seven-byte payload is a single classic frame"
  (define-values (st frames) (start-tx (make-isotp-config) (make-bytes 7 1) 0))
  (check-equal? (tx-state-phase st) 'done)
  (check-equal? (bytes-length (car (due-bytes frames))) 8))

(test-case "tx: segmentation with block size and STmin"
  (define cfg (make-isotp-config #:block-size 2 #:stmin-ms 32))
  (define payload (make-bytes 20 5))
  (define-values (st0 frames0) (start-tx cfg payload 100))
  (check-equal? (tx-state-phase st0) 'wait-fc)
  (check-equal? (due-bytes frames0) (list (bytes-append (bytes #x10 #x14) (make-bytes 6 5))))
  ;; Premature tick: no timeout yet.
  (define-values (st1 f1 o1) (tx-tick cfg st0 1099))
  (check-equal? (outcome-status o1) 'running)
  (check-equal? f1 '())
  ;; FC.CTS, BS=2, STmin=32 ms.
  (define-values (st2 f2 o2) (tx-flow-control cfg st0 (bytes->isotp-frame (bytes #x30 2 #x20)) 100))
  (check-equal? (outcome-status o2) 'running)
  (check-equal? (length f2) 1)                    ; only the CF due at t=100
  (check-equal? (due-frame-ready-at (car f2)) 100)
  (check-equal? (car (due-bytes f2)) (bytes-append (bytes #x21) (make-bytes 7 5)))
  ;; Second CF becomes due at t=132 and completes the payload (6+7+7=20).
  (define-values (st3 f3 o3) (tx-tick cfg st2 132))
  (check-equal? (tx-state-phase st3) 'done)
  (check-equal? (outcome-status o3) 'done)
  (check-equal? (car (due-bytes f3)) (bytes-append (bytes #x22) (make-bytes 7 5))))

(test-case "tx: block exhaustion returns to WAIT_FC and respects N_Bs"
  (define cfg (make-isotp-config #:block-size 1))
  (define payload (make-bytes 20 3))
  (define-values (st0 f0) (start-tx cfg payload 0))
  (define-values (st1 f1 o1) (tx-flow-control cfg st0 (bytes->isotp-frame (bytes #x30 1 0)) 0))
  (check-equal? (length f1) 1)
  (check-equal? (tx-state-phase st1) 'wait-fc)
  (check-equal? (tx-state-fc-wait-start st1) 0)
  (define-values (st2 f2 o2) (tx-tick cfg st1 999))
  (check-equal? (outcome-status o2) 'running)
  (define-values (st3 f3 o3) (tx-tick cfg st1 1000))
  (check-equal? (outcome-status o3) 'error)
  (check-true (string-contains? (outcome-message o3) "N_Bs")))

(test-case "tx: FC.WAIT honored up to the limit, then rejected"
  (define cfg (make-isotp-config #:wait-limit 1))
  (define-values (st0 f0) (start-tx cfg (make-bytes 20 0) 0))
  (define-values (st1 f1 o1) (tx-flow-control cfg st0 (bytes->isotp-frame (bytes #x31 0 0)) 0))
  (check-equal? (outcome-status o1) 'running)
  (define-values (st2 f2 o2) (tx-flow-control cfg st1 (bytes->isotp-frame (bytes #x31 0 0)) 10))
  (check-equal? (outcome-status o2) 'error)
  ;; Default wait-limit 0 rejects the first WAIT.
  (define cfg0 (make-isotp-config))
  (define-values (s0 _) (start-tx cfg0 (make-bytes 20 0) 0))
  (define-values (_s f o) (tx-flow-control cfg0 s0 (bytes->isotp-frame (bytes #x31 0 0)) 0))
  (check-equal? (outcome-status o) 'error))

(test-case "tx: FC.OVFLW aborts the transfer"
  (define cfg (make-isotp-config))
  (define-values (st0 f0) (start-tx cfg (make-bytes 20 0) 0))
  (define-values (_ f o) (tx-flow-control cfg st0 (bytes->isotp-frame (bytes #x32 0 0)) 0))
  (check-equal? (outcome-status o) 'error))

(test-case "tx: sequence number wraps at 16"
  (define cfg (make-isotp-config #:block-size 0))
  (define payload (make-bytes 200 0))             ; FF(6) + 28 CFs
  (define-values (st0 f0) (start-tx cfg payload 0))
  (define-values (st1 f1 _o) (tx-flow-control cfg st0 (bytes->isotp-frame (bytes #x30 0 0)) 0))
  ;; t=0 releases CF #1 only when STmin is 0: all CFs are due immediately.
  (check-equal? (length f1) 28)
  (define sns (map (lambda (bs) (bitwise-and (bytes-ref bs 0) #x0F)) (due-bytes f1)))
  (check-equal? sns
                (append (for/list ([i (in-range 1 16)]) i)
                        (list 0)                       ; wrap
                        (for/list ([i (in-range 1 13)]) i))))

(test-case "tx: padding fills every frame to the frame size"
  (define cfg (make-isotp-config #:tx-padding #xCC))
  (define-values (_st frames) (start-tx cfg (bytes 1 2 3) 0))
  (check-equal? (due-frame-bytes (car frames))
                (bytes #x03 1 2 3 #xCC #xCC #xCC #xCC)))

(test-case "tx: FC while idle is ignored"
  (define cfg (make-isotp-config))
  (define-values (st frames) (start-tx cfg (bytes 1 2 3) 0))
  (define-values (_st2 f o) (tx-flow-control cfg st (bytes->isotp-frame (bytes #x30 8 0)) 0))
  (check-equal? (outcome-status o) 'running)
  (check-equal? f '()))

(test-case "tx: argument validation"
  (check-exn exn:fail? (lambda () (start-tx (make-isotp-config) #"" 0)))
  (check-exn exn:fail? (lambda () (start-tx (make-isotp-config) (make-bytes 4096) 0))))

(test-case "tx: CAN FD segmentation"
  (define cfg (make-isotp-config #:frame-size 64 #:block-size 0))
  (define payload (make-bytes 100 8))
  (define-values (st0 f0) (start-tx cfg payload 0))
  ;; 100 bytes need FF(62) + CF(38).
  (check-equal? (bytes-ref (due-frame-bytes (car f0)) 0) #x10)
  (check-equal? (bytes-length (due-frame-bytes (car f0))) 64) ; FF fills the frame
  (define-values (st1 f1 _o) (tx-flow-control cfg st0 (bytes->isotp-frame (bytes #x30 0 0)) 0))
  (check-equal? (length f1) 1)
  (check-equal? (bytes-ref (due-frame-bytes (car f1)) 0) #x21)
  (check-equal? (bytes-length (due-frame-bytes (car f1))) 39))

(test-case "tx: CAN FD single frame uses the escape form"
  (define cfg (make-isotp-config #:frame-size 64))
  (define payload (make-bytes 10 2))
  (define-values (_st frames) (start-tx cfg payload 0))
  (check-equal? (due-frame-bytes (car frames))
                (bytes-append (bytes #x00 10) payload)))

(test-case "tx: payload above 4095 uses the escaped FF"
  (define cfg (make-isotp-config #:frame-size 64 #:block-size 0 #:max-payload 5000))
  (define payload (make-bytes 5000 4))
  (define-values (st0 f0) (start-tx cfg payload 0))
  (define ff (due-frame-bytes (car f0)))
  (check-equal? (subbytes ff 0 6) (bytes #x10 #x00 #x00 #x00 #x13 #x88)) ; 5000
  (check-equal? (bytes-length ff) 64))

;; ---------------------------------------------------------------------------
;; Receiver state machine

(define classic-rx (make-isotp-config #:block-size 2 #:stmin-ms 32 #:n-cr 1000))

(test-case "rx: multi-frame reception with block-based flow control"
  (define st0 (make-rx-state classic-rx))
  (define payload (make-bytes 20 5))
  (define-values (st1 got1 fc1 o1)
    (rx-frame classic-rx st0 (bytes-append (bytes #x10 #x14) (make-bytes 6 5)) 0))
  (check-equal? got1 #f)
  (check-equal? (outcome-status o1) 'running)
  (check-equal? (due-frame-bytes fc1) (bytes #x30 2 #x20)) ; CTS, BS=2, STmin=32ms
  (match-define (list st2 got2 fc2 _o2) (rx-f classic-rx st1 (bytes-append (bytes #x21) (make-bytes 7 5)) 10))
  (check-false got2) (check-false fc2)
  (match-define (list st3 got3 fc3 o3) (rx-f classic-rx st2 (bytes-append (bytes #x22) (make-bytes 7 5)) 20))
  (check-equal? got3 payload)
  (check-false fc3)
  (check-equal? (outcome-status o3) 'done)
  (check-equal? (rx-state-phase st3) 'idle))

(test-case "rx: emits a new CTS when the block is exhausted"
  (define cfg (make-isotp-config #:block-size 2))
  (define st0 (make-rx-state cfg))
  (define payload (make-bytes 30 7))
  (match-define (list st1 _ fc1 _) (rx-f cfg st0 (bytes-append (bytes #x10 #x1E) (make-bytes 6 7)) 0))
  (check-equal? (due-frame-bytes fc1) (bytes #x30 2 0))
  (match-define (list st2 _ fc2 _) (rx-f cfg st1 (bytes-append (bytes #x21) (make-bytes 7 7)) 1))
  (check-false fc2)
  (match-define (list st3 _ fc3 _) (rx-f cfg st2 (bytes-append (bytes #x22) (make-bytes 7 7)) 2))
  (check-equal? (due-frame-bytes fc3) (bytes #x30 2 0))) ; second window

(test-case "rx: sequence number mismatch fails the connection"
  (define st0 (make-rx-state classic-rx))
  (match-define (list st1 _ fc1 _) (rx-f classic-rx st0 (bytes-append (bytes #x10 #x14) (make-bytes 6 0)) 0))
  (match-define (list st2 got fc o) (rx-f classic-rx st1 (bytes-append (bytes #x25) (make-bytes 7 0)) 1))
  (check-equal? (rx-state-phase st2) 'error)
  (check-equal? (outcome-status o) 'error)
  ;; A failed connection stays failed.
  (match-define (list _s _g _f o2) (rx-f classic-rx st2 (bytes-append (bytes #x22) (make-bytes 7 0)) 2))
  (check-equal? (outcome-status o2) 'error))

(test-case "rx: N_Cr timeout"
  (define st0 (make-rx-state classic-rx))
  (match-define (list st1 _ _ _) (rx-f classic-rx st0 (bytes-append (bytes #x10 #x14) (make-bytes 6 0)) 0))
  (match-define (list _s _g _f o1) (rx-t classic-rx st1 999))
  (check-equal? (outcome-status o1) 'running)
  (match-define (list _s2 _g2 _f2 o2) (rx-t classic-rx st1 1000))
  (check-equal? (outcome-status o2) 'error))

(test-case "rx: buffer overflow answers FC.OVFLW"
  (define cfg (make-isotp-config #:rx-buffer-size 100))
  (define st0 (make-rx-state cfg))
  ;; Declares 0x081 = 129 bytes, above the 100-byte buffer.
  (match-define (list _st got fc o) (rx-f cfg st0 (bytes-append (bytes #x10 #x81) (make-bytes 6 0)) 0))
  (check-false got)
  (check-equal? (due-frame-bytes fc) (bytes #x32 8 0))  ; OVFLW
  (check-equal? (outcome-status o) 'running)
  (check-equal? (rx-state-phase _st) 'idle))

(test-case "rx: duplicate first frame ignored, changed first frame restarts"
  (define st0 (make-rx-state classic-rx))
  (define ff (bytes-append (bytes #x10 #x14) (make-bytes 6 0)))
  (match-define (list st1 _ fc1 _) (rx-f classic-rx st0 ff 0))
  (match-define (list st2 got2 fc2 _) (rx-f classic-rx st1 ff 1))
  (check-false got2) (check-false fc2)
  (check-equal? (rx-state-received st2) (rx-state-received st1))
  (define ff2 (bytes-append (bytes #x10 #x1E) (make-bytes 6 1)))
  (match-define (list st3 _got3 fc3 _) (rx-f classic-rx st2 ff2 2))
  (check-equal? (due-frame-bytes fc3) (bytes #x30 2 #x20))
  (check-equal? (rx-state-total st3) 30))

(test-case "rx: single frame interrupts an ongoing reception"
  (define st0 (make-rx-state classic-rx))
  (match-define (list st1 _ _ _) (rx-f classic-rx st0 (bytes-append (bytes #x10 #x14) (make-bytes 6 0)) 0))
  (match-define (list _st got _fc o) (rx-f classic-rx st1 (bytes #x02 9 9) 1))
  (check-equal? got (bytes 9 9))
  (check-equal? (outcome-status o) 'done))

(test-case "rx: consecutive frame while idle is ignored"
  (define st0 (make-rx-state classic-rx))
  (match-define (list _st got _fc o) (rx-f classic-rx st0 (bytes-append (bytes #x21) (make-bytes 7 0)) 0))
  (check-false got)
  (check-equal? (outcome-status o) 'running))

(test-case "rx: rx-padding rejects short frames"
  (define cfg (make-isotp-config #:rx-padding 8))
  (define st0 (make-rx-state cfg))
  (match-define (list _st got _fc o) (rx-f cfg st0 (bytes #x02 1 2) 0))
  (check-false got)
  (check-equal? (outcome-status o) 'running))

(test-case "rx: last CF may be padded beyond the declared total"
  (define st0 (make-rx-state classic-rx))
  (match-define (list st1 _ _ _) (rx-f classic-rx st0 (bytes-append (bytes #x10 #x08) (bytes 1 1 1 1 1 1)) 0))
  (match-define (list _st got _fc o) (rx-f classic-rx st1 (bytes-append (bytes #x21 2 2) (make-bytes 5 #x55)) 1))
  (check-equal? got (bytes 1 1 1 1 1 1 2 2))
  (check-equal? (bytes-length got) 8)
  (check-equal? (subbytes got 6) (bytes 2 2)))

;; ---------------------------------------------------------------------------
;; Loopback: both machines wired together

;; Drives a full transfer between a sender and a receiver over an idealized
;; bus.  `tx-cfg` and `rx-cfg` are the two ends (mirrored addressing: a node
;; receives frames whose addressing prefix names *it*).  Advances a logical
;; millisecond clock; returns the payload the receiver delivered and the
;; number of CAN frames exchanged.
(define (run-transfer tx-cfg rx-cfg payload)
  (define-values (st0 f0) (start-tx tx-cfg payload 0))
  (let drive ([t 0]
              [txst st0]
              [rxst (make-rx-state rx-cfg)]
              [txq f0]                         ; due-frames not yet "transmitted"
              [rxq '()]
              [frames-sent 0]
              [delivered #f]
              [guard 0])
    (cond
      [(> guard 100000) (error 'run-transfer "livelock")]
      [(and delivered (null? txq) (null? rxq) (eq? (tx-state-phase txst) 'done))
       (values delivered frames-sent)]
      [else
       (cond
         ;; Deliver one due tx frame into the receiver.
         [(pair? txq)
          (define f (car txq))
          (define t1 (max t (due-frame-ready-at f)))
          (match-define (list rxst1 got fc _o) (rx-f rx-cfg rxst (due-frame-bytes f) t1))
          (drive t1 txst rxst1 (cdr txq) (if fc (cons fc rxq) rxq) (add1 frames-sent) (or got delivered) (add1 guard))]
         ;; Deliver one due rx flow-control frame into the sender.
         [(pair? rxq)
          (define f (car rxq))
          (define t1 (max t (due-frame-ready-at f)))
          (define fc (bytes->isotp-frame (due-frame-bytes f) (config-prefix-size rx-cfg)))
          (define-values (txst1 new-frames o) (tx-flow-control tx-cfg txst fc t1))
          (when (eq? (outcome-status o) 'error)
            (error 'run-transfer "tx error: ~a" (outcome-message o)))
          (drive t1 txst1 rxst (append txq new-frames) (cdr rxq) (add1 frames-sent) delivered (add1 guard))]
         ;; Nothing due: pump both machines for timeouts and pacing.
         [else
          (define t1 (add1 t))
          (define-values (txst1 new-frames o1) (tx-tick tx-cfg txst t1))
          (when (eq? (outcome-status o1) 'error)
            (error 'run-transfer "tx error: ~a" (outcome-message o1)))
          (match-define (list _rxst2 _got _fc _o2) (rx-t rx-cfg rxst t1))
          (drive t1 txst1 rxst (append txq new-frames) rxq frames-sent delivered (add1 guard))])])))

(test-case "loopback: 300-byte transfer with block size 3"
  (define cfg (make-isotp-config #:block-size 3))
  (define payload (list->bytes (build-list 300 (lambda (i) (modulo i 251)))))
  (define-values (delivered frames) (run-transfer cfg cfg payload))
  (check-equal? delivered payload)
  ;; 1 FF + 42 CFs, plus 14 CTS flow-control frames (initial + one per
  ;; 3-CF block; the final CF completes instead of asking for more).
  (check-equal? frames 57))

(test-case "loopback: CAN FD transfer of 1000 bytes"
  (define cfg (make-isotp-config #:frame-size 64 #:block-size 0))
  (define payload (list->bytes (build-list 1000 (lambda (i) (modulo (* i 7) 256)))))
  (define-values (delivered frames) (run-transfer cfg cfg payload))
  (check-equal? delivered payload)
  (check-equal? frames 17)) ; FF(62) + 15 CFs (14×63 + 56), plus 1 CTS

(test-case "loopback: extended addressing"
  ;; Extended addressing is directional: the sender prefixes the frame with
  ;; the *target*'s address, and the receiver checks its *own* address, so a
  ;; loopback needs the mirrored config pair.
  (define tx-cfg (make-isotp-config #:addressing 'extended-11
                                    #:tx-id #x123 #:rx-id #x456
                                    #:target-address #x10 #:source-address #xF1
                                    #:block-size 2))
  (define rx-cfg (make-isotp-config #:addressing 'extended-11
                                    #:tx-id #x456 #:rx-id #x123
                                    #:target-address #xF1 #:source-address #x10
                                    #:block-size 2))
  (define payload (make-bytes 50 3))
  (define-values (delivered frames) (run-transfer tx-cfg rx-cfg payload))
  (check-equal? delivered payload))

(test-case "loopback: fixed 29-bit addressing with mixed frame sizes"
  (define cfg (make-isotp-config #:addressing 'normal-fixed-29
                                 #:target-address #x10 #:source-address #xF1
                                 #:block-size 0 #:stmin-us 100))
  (define payload (make-bytes 200 11))
  (define-values (delivered frames) (run-transfer cfg cfg payload))
  (check-equal? delivered payload))
