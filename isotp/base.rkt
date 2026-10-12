#lang racket/base

;; Shared data types for the isotp package.

(require racket/contract)

(provide (contract-out
          (struct outcome
            ((status symbol?)
             (message string?)))
          (struct due-frame
            ((bytes bytes?)
             (ready-at real?)))
          [make-error-outcome (-> string? outcome?)]
          [make-done-outcome (-> string? outcome?)]
          [make-running-outcome (-> string? outcome?)]))

;; Result status of a state-machine step:
;;   'running — waiting for more events
;;   'done    — a complete network-layer message was produced or delivered
;;   'error   — the connection failed; the message says why
(struct outcome (status message) #:transparent)

;; A frame the caller must put on the bus.  `ready-at` is a timestamp in
;; milliseconds on the same clock as the `now` argument of the event
;; functions; the caller must not transmit before that time.
(struct due-frame (bytes ready-at) #:transparent)

(define (make-error-outcome message) (outcome 'error message))
(define (make-done-outcome message) (outcome 'done message))
(define (make-running-outcome message) (outcome 'running message))
