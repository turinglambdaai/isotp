#lang racket/base

;; Connection configuration (ISO 15765-2 "N_AI" plus timing and padding
;; parameters).  One `isotp-config` value describes one point-to-point
;; ISO-TP connection; the same value is handed to the sender and receiver
;; state machines.

(require racket/contract)

(provide (contract-out
          (struct isotp-config
            ((addressing symbol?)
             (tx-id (or/c #f exact-nonnegative-integer?))
             (rx-id (or/c #f exact-nonnegative-integer?))
             (target-address (or/c #f (integer-in 0 255)))
             (source-address (or/c #f (integer-in 0 255)))
             (address-extension (or/c #f (integer-in 0 255)))
             (physical-id (or/c #f exact-nonnegative-integer?))
             (functional-id (or/c #f exact-nonnegative-integer?))
             (frame-size (integer-in 8 64))
             (block-size (integer-in 0 255))
             (stmin-us exact-nonnegative-integer?)
             (n-bs real?)
             (n-cr real?)
             (wait-limit exact-nonnegative-integer?)
             (max-payload exact-nonnegative-integer?)
             (rx-buffer-size exact-nonnegative-integer?)
             (tx-padding (or/c #f (integer-in 0 255)))
             (rx-padding (or/c #f (integer-in 1 64)))))
          [make-isotp-config
           (->* ()
                (#:addressing (or/c 'normal-11 'normal-29 'normal-fixed-29
                                    'extended-11 'extended-29 'mixed-11 'mixed-29)
                 #:tx-id (or/c #f exact-nonnegative-integer?)
                 #:rx-id (or/c #f exact-nonnegative-integer?)
                 #:target-address (or/c #f (integer-in 0 255))
                 #:source-address (or/c #f (integer-in 0 255))
                 #:address-extension (or/c #f (integer-in 0 255))
                 #:physical-id (or/c #f exact-nonnegative-integer?)
                 #:functional-id (or/c #f exact-nonnegative-integer?)
                 #:frame-size (integer-in 8 64)
                 #:block-size (integer-in 0 255)
                 #:stmin-ms (or/c #f (integer-in 0 127))
                 #:stmin-us (or/c #f (integer-in 100 900))
                 #:n-bs (real-in 0 +inf.0)
                 #:n-cr (real-in 0 +inf.0)
                 #:wait-limit exact-nonnegative-integer?
                 #:max-payload exact-nonnegative-integer?
                 #:rx-buffer-size exact-nonnegative-integer?
                 #:tx-padding (or/c #f (integer-in 0 255))
                 #:rx-padding (or/c #f (integer-in 1 64)))
                isotp-config?)]
          [config-fd? (-> isotp-config? boolean?)]
          [config-prefix-size (-> isotp-config? (integer-in 0 1))]
          [config-data-capacity (-> isotp-config? exact-nonnegative-integer?)]))

;; ISO 15765-2 addressing modes.  `normal-11` / `normal-29` carry no address
;; information in the payload.  `extended-*` spend the first payload byte on
;; the target address.  `normal-fixed-29` and `mixed-29` encode the addresses
;; in the 29-bit CAN identifier (see address.rkt); `mixed-*` additionally
;; carry an address-extension byte as the first payload byte.
(struct isotp-config
  (addressing            ; symbol, one of the modes above
   tx-id                 ; CAN id used for transmission (normal/extended modes)
   rx-id                 ; CAN id accepted for reception (normal/extended modes)
   target-address        ; N_TA — the remote node's address (fixed/mixed modes)
   source-address        ; N_SA — this node's address (fixed/mixed modes)
   address-extension     ; N_AE (mixed modes)
   physical-id           ; 29-bit id prefix, bits 28-16, physical (fixed/mixed)
   functional-id         ; 29-bit id prefix, bits 28-16, functional (fixed/mixed)
   frame-size            ; tx CAN_DL: 8 for classic CAN, 12..64 for CAN FD
   block-size            ; BS: CFs per flow-control window, 0 = unlimited
   stmin-us              ; STmin in microseconds (wire encoding in frame.rkt)
   n-bs                  ; ms — timeout waiting for FC after FF (or block end)
   n-cr                  ; ms — timeout waiting for the next CF
   wait-limit            ; consecutive FC.WAIT tolerated, 0 rejects WAIT
   max-payload           ; largest payload start-tx accepts
   rx-buffer-size        ; larger FF declarations are answered with OVFLW
   tx-padding            ; #f or a fill byte; frames padded up to frame-size
   rx-padding            ; #f or the minimum CAN_DL accepted on reception
   )
  #:transparent)

(define +can-fd-sizes+ '(8 12 16 20 24 32 48 64))

(define (make-isotp-config
         #:addressing [addressing 'normal-11]
         #:tx-id [tx-id #f]
         #:rx-id [rx-id #f]
         #:target-address [target-address #f]
         #:source-address [source-address #f]
         #:address-extension [address-extension #f]
         #:physical-id [physical-id #f]
         #:functional-id [functional-id #f]
         #:frame-size [frame-size 8]
         #:block-size [block-size 8]
         #:stmin-ms [stmin-ms #f]
         #:stmin-us [stmin-us-kw #f]
         #:n-bs [n-bs 1000]
         #:n-cr [n-cr 1000]
         #:wait-limit [wait-limit 0]
         #:max-payload [max-payload 4095]
         #:rx-buffer-size [rx-buffer-size 4095]
         #:tx-padding [tx-padding #f]
         #:rx-padding [rx-padding #f])
  (define fd? (> frame-size 8))
  (unless (memv frame-size +can-fd-sizes+)
    (error 'make-isotp-config
           "frame-size must be a legal CAN DLC: 8, 12, 16, 20, 24, 32, 48 or 64, got ~a"
           frame-size))
  (when (and stmin-ms stmin-us-kw)
    (error 'make-isotp-config "give either #:stmin-ms or #:stmin-us, not both"))
  (define stmin-final
    (cond [stmin-us-kw stmin-us-kw]
          [stmin-ms (* stmin-ms 1000)]
          [else 0]))
  (define uses-fixed? (memq addressing '(normal-fixed-29 mixed-29)))
  ;; CAN identifiers are only needed by the isotp-tx-id / isotp-rx-id
  ;; helpers, so their presence is validated there; range is checked here.
  (when tx-id
    (define limit (if (memq addressing '(normal-11 extended-11 mixed-11)) #x7FF #x1FFFFFFF))
    (when (> tx-id limit)
      (error 'make-isotp-config "tx-id ~a exceeds the ~a-bit identifier range" tx-id
             (if (= limit #x7FF) "11" "29"))))
  (when (and rx-id
             (> rx-id (if (memq addressing '(normal-11 extended-11 mixed-11)) #x7FF #x1FFFFFFF)))
    (error 'make-isotp-config "rx-id out of range"))
  (when uses-fixed?
    (when tx-id (error 'make-isotp-config "~a derives ids from addresses; do not pass #:tx-id" addressing))
    (when rx-id (error 'make-isotp-config "~a derives ids from addresses; do not pass #:rx-id" addressing))
    (unless (and target-address source-address)
      (error 'make-isotp-config "addressing mode ~a requires #:target-address and #:source-address" addressing)))
  (when (memq addressing '(mixed-11 mixed-29))
    (unless address-extension
      (error 'make-isotp-config "addressing mode ~a requires #:address-extension" addressing)))
  (when (and (not fd?) (> max-payload 4095))
    (error 'make-isotp-config "classic CAN (frame-size 8) carries at most 4095 bytes; got ~a" max-payload))
  (when (> max-payload #xFFFFFFFF)
    (error 'make-isotp-config "payload length is limited to 4294967295 by the FF escape encoding"))
  (isotp-config addressing
                tx-id rx-id
                target-address source-address address-extension
                (and physical-id (bitwise-and physical-id #x1FFF0000))
                (and functional-id (bitwise-and functional-id #x1FFF0000))
                frame-size block-size stmin-final n-bs n-cr wait-limit
                max-payload rx-buffer-size tx-padding rx-padding))

(define (config-fd? cfg) (> (isotp-config-frame-size cfg) 8))

;; Number of payload bytes spent on addressing (extended / mixed modes).
(define (config-prefix-size cfg)
  (if (memq (isotp-config-addressing cfg) '(extended-11 extended-29 mixed-11 mixed-29)) 1 0))

;; Payload bytes available per full frame (CAN_DL minus the address prefix).
(define (config-data-capacity cfg)
  (- (isotp-config-frame-size cfg) (config-prefix-size cfg)))
