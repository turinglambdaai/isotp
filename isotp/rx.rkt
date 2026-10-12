#lang racket/base

;; Receiver state machine (ISO 15765-2 receiver role): reassembles multi-frame
;; payloads, emits flow control (CTS / OVFLW, block size, STmin) and reports
;; N_Cr timeouts.
;;
;; Pure and transport-agnostic like the sender: event functions take a
;; millisecond timestamp and return the new state, an optional complete
;; payload, optional flow-control bytes to put on the bus, and an `outcome`.

(require racket/contract
         "base.rkt"
         "config.rkt"
         "frame.rkt")

(provide (contract-out
          (struct rx-state
            ((phase symbol?)   ; 'idle 'wait-cf 'error
             (total (or/c #f exact-nonnegative-integer?))
             (chunks (listof bytes?)) ; received byte chunks in reverse order
             (received real?)
             (expected-sn (integer-in 0 15))
             (cf-since-fc exact-nonnegative-integer?)
             (last-activity real?)
             (message string?)))
          [make-rx-state (-> isotp-config? rx-state?)]
          [rx-frame
           (-> isotp-config? rx-state? bytes? real?
               (values rx-state? (or/c #f bytes?) (or/c #f due-frame?) outcome?))]
          [rx-tick
           (-> isotp-config? rx-state? real?
               (values rx-state? (or/c #f bytes?) (or/c #f due-frame?) outcome?))]))

(struct rx-state (phase total chunks received expected-sn cf-since-fc last-activity message)
  #:transparent)

(define (make-rx-state cfg)
  (rx-state 'idle #f '() 0 0 0 0 ""))

;; ---------------------------------------------------------------------------
;; helpers

(define (rx-prefix-ok? cfg payload)
  (case (isotp-config-addressing cfg)
    [(extended-11 extended-29)
     (equal? (subbytes payload 0 1) (bytes (isotp-config-source-address cfg)))]
    [(mixed-11 mixed-29)
     (equal? (subbytes payload 0 1) (bytes (isotp-config-address-extension cfg)))]
    [else #t]))

;; Encode an FC frame the way this connection transmits (padding + prefix).
(define (rx-encode-fc cfg flow-status)
  (define frame (fc-frame flow-status (isotp-config-block-size cfg) (isotp-config-stmin-us cfg)))
  (define prefix
    (case (isotp-config-addressing cfg)
      [(extended-11 extended-29) (bytes (isotp-config-target-address cfg))]
      [(mixed-11 mixed-29) (bytes (isotp-config-address-extension cfg))]
      [else #""]))
  (define fill
    (if (isotp-config-tx-padding cfg)
        (- (isotp-config-frame-size cfg) (bytes-length prefix))
        0))
  (bytes-append prefix
                (isotp-frame->bytes frame
                                    #:fill fill
                                    #:pad-byte (or (isotp-config-tx-padding cfg) 0))))

(define (join-chunks chunks)
  (apply bytes-append (reverse chunks)))

;; Fail the connection.
(define (rx-fail st message)
  (values (struct-copy rx-state st [phase 'error] [message message])
          #f #f (make-error-outcome message)))

;; Deliver a completed payload and go idle.
(define (rx-deliver st payload message)
  (values (rx-state 'idle #f '() 0 0 0 0 message)
          payload
          #f
          (make-done-outcome message)))

;; Start (or restart) reception after a valid first frame; returns the new
;; state and the FC frame to transmit — or completes immediately when the FF
;; already carried the whole (technically non-compliant, but decodable)
;; message.
(define (rx-start-after-ff cfg st frame now)
  (define total (isotp-frame-sequence-number frame))
  (cond
    [(> total (isotp-config-rx-buffer-size cfg))
     (values (struct-copy rx-state st
                          [phase 'idle] [total #f] [chunks '()] [received 0]
                          [message (format "payload of ~a byte(s) exceeds the reception buffer" total)])
             #f
             (due-frame (rx-encode-fc cfg 'overflow) now)
             (make-running-outcome "buffer overflow, FC.OVFLW sent"))]
    ;; The FF may carry more data bytes than it declares (padding); keep
    ;; only the declared ones.
    [(>= (bytes-length (isotp-frame-data frame)) total)
     (rx-deliver st (subbytes (isotp-frame-data frame) 0 total) "message carried entirely by the first frame")]
    [else
     (values (struct-copy rx-state st
                          [phase 'wait-cf]
                          [total total]
                          [chunks (list (isotp-frame-data frame))]
                          [received (bytes-length (isotp-frame-data frame))]
                          [expected-sn 1]
                          [cf-since-fc 0]
                          [last-activity now]
                          [message "first frame accepted, FC.CTS sent"])
             #f
             (due-frame (rx-encode-fc cfg 'cts) now)
             (make-running-outcome "reception started"))]))

;; ---------------------------------------------------------------------------
;; events

;; Feed one received CAN payload (identifier excluded, addressing prefix
;; included).  Returns the new state, a completed payload if one arrived, FC
;; bytes to transmit if any are due, and an outcome.
(define (rx-frame cfg st payload now)
  (case (rx-state-phase st)
    [(error) (values st #f #f (make-error-outcome (rx-state-message st)))]
    [else
     (cond
       [(and (isotp-config-rx-padding cfg)
             (< (bytes-length payload) (isotp-config-rx-padding cfg)))
        (values st #f #f (make-running-outcome "frame shorter than #:rx-padding, ignored"))]
       [(not (rx-prefix-ok? cfg payload))
        (values st #f #f (make-running-outcome "addressing prefix mismatch, ignored"))]
       [else
        (define frame (bytes->isotp-frame payload (config-prefix-size cfg)))
        (case (isotp-frame-type frame)
          [(fc)
           (values st #f #f (make-running-outcome "flow control ignored: this connection receives, not sends"))]
          [(sf)
           ;; A single frame always delivers a fresh message; one already in
           ;; flight is aborted.
           (rx-deliver st (isotp-frame-data frame)
                       (if (eq? (rx-state-phase st) 'wait-cf)
                           "reception interrupted by a single frame"
                           "single frame"))]
          [(ff)
           (define total (isotp-frame-sequence-number frame))
           (cond
             ;; Retransmitted first frame of the message in flight: ignore.
             [(and (eq? (rx-state-phase st) 'wait-cf) (= total (rx-state-total st)))
              (values st #f #f (make-running-outcome "duplicate first frame, ignored"))]
             [else (rx-start-after-ff cfg st frame now)])]
          [(cf)
           (cond
             [(not (eq? (rx-state-phase st) 'wait-cf))
              (values st #f #f (make-running-outcome "consecutive frame while idle, ignored"))]
             [(not (= (isotp-frame-sequence-number frame) (rx-state-expected-sn st)))
              (rx-fail st (format "sequence number mismatch: got ~a, expected ~a"
                                  (isotp-frame-sequence-number frame)
                                  (rx-state-expected-sn st)))]
             [else
              (define remaining (- (rx-state-total st) (rx-state-received st)))
              (define data
                ;; Trailing padding may overrun the declared total.
                (if (<= (bytes-length (isotp-frame-data frame)) remaining)
                    (isotp-frame-data frame)
                    (subbytes (isotp-frame-data frame) 0 remaining)))
              (define received (+ (rx-state-received st) (bytes-length data)))
              (cond
                [(>= received (rx-state-total st))
                 (define chunks (cons data (rx-state-chunks st)))
                 (rx-deliver (struct-copy rx-state st [chunks chunks])
                             (join-chunks chunks)
                             "multi-frame message complete")]
                [else
                 (define expected (rx-state-expected-sn st))
                 (define st1 (struct-copy rx-state st
                                          [chunks (cons data (rx-state-chunks st))]
                                          [received received]
                                          [expected-sn (modulo (+ expected 1) 16)]
                                          [cf-since-fc (add1 (rx-state-cf-since-fc st))]
                                          [last-activity now]
                                          [message "consecutive frame accepted"]))
                 (define need-fc? (and (> (isotp-config-block-size cfg) 0)
                                       (>= (rx-state-cf-since-fc st1)
                                           (isotp-config-block-size cfg))))
                 (define st2 (if need-fc?
                                 (struct-copy rx-state st1 [cf-since-fc 0])
                                 st1))
                 (values st2
                         #f
                         (and need-fc? (due-frame (rx-encode-fc cfg 'cts) now))
                         (make-running-outcome "consecutive frame accepted"))])])])])]))

;; Advance time and detect the N_Cr timeout (waiting for the next CF).
(define (rx-tick cfg st now)
  (case (rx-state-phase st)
    [(wait-cf)
     (if (>= (- now (rx-state-last-activity st)) (isotp-config-n-cr cfg))
         (rx-fail st "N_Cr timed out waiting for a consecutive frame")
         (values st #f #f (make-running-outcome (rx-state-message st))))]
    [else (values st #f #f (make-running-outcome (rx-state-message st)))]))
