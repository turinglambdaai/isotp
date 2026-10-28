#lang racket/base
;; No transport driver, network or ECU needed.
(require isotp)

(define payload #"hello")
(define frame (sf-frame payload))
(define encoded (isotp-frame->bytes frame))
(unless (bytes=? encoded (bytes #x05 104 101 108 108 111))
  (error 'isotp-quickstart "expected CAN single-frame encoding"))
(unless (bytes=? (isotp-frame-data (bytes->isotp-frame encoded)) payload)
  (error 'isotp-quickstart "single-frame round trip failed"))

;; A fixed 29-bit functional request identifier.
(define cfg (make-isotp-config #:addressing 'normal-fixed-29
                               #:target-address #x33
                               #:source-address #xF1))
(unless (= (isotp-tx-id cfg #t) #x18DB33F1)
  (error 'isotp-quickstart "normal-fixed-29 identifier mismatch"))

(displayln "ISO-TP quickstart OK")
