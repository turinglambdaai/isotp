#lang racket/base

;; CAN identifier helpers for the ISO 15765-2 fixed-addressing modes.
;;
;; In `normal-fixed-29` and `mixed-29` mode the node addresses live in the
;; 29-bit identifier, laid out as
;;
;;     [28:26] priority      (part of the mode prefix)
;;     [25:24] reserved      (part of the mode prefix)
;;     [23:16] mode byte     (0xDA physical / 0xDB functional; 0xCE / 0xCD
;;                            when an address extension byte is used)
;;     [15:8]  one address   (target when transmitting, source when receiving)
;;     [ 7:0]  other address
;;
;; The defaults follow the standard-mandated values (physical 0x18DA0000,
;; functional 0x18DB0000, mixed 0x18CE0000 / 0x18CD0000) and can be
;; overridden through `#:physical-id` / `#:functional-id` (bits 28-16).

(require racket/contract
         "config.rkt")

(provide +fixed-physical-prefix+
         +fixed-functional-prefix+
         +mixed-physical-prefix+
         +mixed-functional-prefix+)

(provide (contract-out
          [isotp-tx-id (->* (isotp-config?) (boolean?) exact-nonnegative-integer?)]
          [isotp-rx-id (->* (isotp-config?) (boolean?) exact-nonnegative-integer?)]))

(define +fixed-physical-prefix+   #x18DA0000)
(define +fixed-functional-prefix+ #x18DB0000)
(define +mixed-physical-prefix+   #x18CE0000)
(define +mixed-functional-prefix+ #x18CD0000)

(define (fixed-prefix cfg functional?)
  (define addressing (isotp-config-addressing cfg))
  (cond
    [(memq addressing '(normal-fixed-29 mixed-29))
     (define default
       (if (eq? addressing 'mixed-29)
           (if functional? +mixed-functional-prefix+ +mixed-physical-prefix+)
           (if functional? +fixed-functional-prefix+ +fixed-physical-prefix+)))
     (or (and functional? (isotp-config-functional-id cfg))
         (and (not functional?) (isotp-config-physical-id cfg))
         default)]
    [else (error 'fixed-prefix "addressing mode ~a has no fixed-addressing prefix" addressing)]))

;; Arbitration id this node transmits on.  `functional?` selects the
;; functional (1-to-n) id instead of the physical (1-to-1) id.
(define (isotp-tx-id cfg [functional? #f])
  (case (isotp-config-addressing cfg)
    [(normal-11 normal-29 extended-11 extended-29 mixed-11)
     (or (isotp-config-tx-id cfg)
         (error 'isotp-tx-id "addressing mode ~a needs #:tx-id" (isotp-config-addressing cfg)))]
    [(normal-fixed-29 mixed-29)
     (bitwise-ior (fixed-prefix cfg functional?)
                  (arithmetic-shift (isotp-config-target-address cfg) 8)
                  (isotp-config-source-address cfg))]))

;; Arbitration id this node receives on.
(define (isotp-rx-id cfg [functional? #f])
  (case (isotp-config-addressing cfg)
    [(normal-11 normal-29 extended-11 extended-29 mixed-11)
     (or (isotp-config-rx-id cfg)
         (error 'isotp-rx-id "addressing mode ~a needs #:rx-id" (isotp-config-addressing cfg)))]
    [(normal-fixed-29 mixed-29)
     (bitwise-ior (fixed-prefix cfg functional?)
                  (arithmetic-shift (isotp-config-source-address cfg) 8)
                  (isotp-config-target-address cfg))]))
