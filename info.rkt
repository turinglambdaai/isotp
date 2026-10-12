#lang info

(define version "0.1")
;; Multi-collection package shape: the collection is the `isotp/` subdirectory.
;; `collection 'multi` is the standard declaration for this layout.
(define collection 'multi)
;; rackunit-lib is a run-time dependency (not merely a build-time one)
;; because the package ships its test suite, and the catalog's dependency
;; check scans shipped modules in run mode.
(define deps '("base" "rackunit-lib"))
(define build-deps '("base" "scribble-lib" "racket-doc" "rackunit-lib"))
(define pkg-desc "Pure-Racket ISO 15765-2 (ISO-TP) transport layer for CAN: frame codec, sender and receiver state machines, classic CAN and CAN FD")
(define pkg-authors '("turinglambdaai"))
(define license 'MIT)
(define scribblings '(("isotp/scribblings/isotp.scrbl" ())))
;; Loading the scribblings as a "test" produces no tests and noise; skip it.
(define test-omit-paths '("isotp/scribblings"))
