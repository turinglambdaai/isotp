#lang racket/base

;; Sender state machine (ISO 15765-2 sender role): segments a payload into
;; SF / FF / CF frames, honours flow control (CTS / WAIT / OVFLW, block size,
;; STmin pacing) and reports N_Bs timeouts.
;;
;; The machine is pure and transport-agnostic.  Every event function takes a
;; millisecond timestamp `now` (any monotonic clock works) and returns the
;; new state, a list of `due-frame`s to put on the bus, and an `outcome`.
;; Frames carry a `ready-at` timestamp: the caller must not transmit a frame
;; before its time.  Call `tx-tick` periodically to drain frames whose time
;; has come and to detect timeouts.

(require racket/contract
         "base.rkt"
         "config.rkt"
         "frame.rkt")

(provide (contract-out
          (struct tx-state
            ((phase symbol?)  ; 'idle 'wait-fc 'send-cf 'done 'error
             (payload bytes?)
             (offset real?)
             (next-sn (integer-in 0 15))
             (block-left real?)          ; +inf.0 for an unlimited window
             (next-ready-at real?)
             (fc-wait-start real?)
             (wait-count exact-nonnegative-integer?)
             (granted-stmin-us real?)    ; STmin granted by the peer's FC, in microseconds
             (message string?)))
          [start-tx (-> isotp-config? bytes? real?
                        (values tx-state? (listof due-frame?)))]
          [tx-flow-control
           (-> isotp-config? tx-state? isotp-frame? real?
               (values tx-state? (listof due-frame?) outcome?))]
          [tx-tick
           (-> isotp-config? tx-state? real?
               (values tx-state? (listof due-frame?) outcome?))]))

(struct tx-state (phase payload offset next-sn block-left next-ready-at fc-wait-start wait-count granted-stmin-us message)
  #:transparent)

;; ---------------------------------------------------------------------------
;; helpers

;; Addressing prefix bytes that precede the PCI in every transmitted frame.
(define (tx-prefix cfg)
  (case (isotp-config-addressing cfg)
    [(extended-11 extended-29) (bytes (isotp-config-target-address cfg))]
    [(mixed-11 mixed-29) (bytes (isotp-config-address-extension cfg))]
    [else #""]))

;; Encode `frame` as wire bytes, applying the connection's padding policy and
;; addressing prefix.  Padding fills up to frame-size *including* the prefix.
(define (tx-encode cfg frame)
  (define prefix (tx-prefix cfg))
  (define fill
    (if (isotp-config-tx-padding cfg)
        (- (isotp-config-frame-size cfg) (bytes-length prefix))
        0))
  (define padded (isotp-frame->bytes frame #:fill fill #:pad-byte (or (isotp-config-tx-padding cfg) 0)))
  (bytes-append prefix padded))

(define (sf-capacity cfg)
  ;; The SF PCI is 1 byte in the plain form and 2 bytes in the escape form.
  (- (config-data-capacity cfg) (if (config-fd? cfg) 2 1)))

(define (ff-first-chunk cfg total)
  (define capacity (config-data-capacity cfg))
  (if (and (config-fd? cfg) (> total 4095))
      (min total (- capacity 6))     ; escaped FF: 6-byte PCI
      (min total (- capacity 2))))   ; 12-bit FF: 2-byte PCI

(define (cf-chunk-size cfg)
  (- (config-data-capacity cfg) 1))

(define (tx-fail st message)
  (values (struct-copy tx-state st [phase 'error] [message message])
          '()
          (make-error-outcome message)))

;; Outcome for a state the caller is polling.
(define (phase-outcome st)
  (case (tx-state-phase st)
    [(done) (make-done-outcome (tx-state-message st))]
    [(error) (make-error-outcome (tx-state-message st))]
    [else (make-running-outcome (tx-state-message st))]))

;; ---------------------------------------------------------------------------
;; events

;; Begin sending `payload`.  Returns the initial state and either the single
;; SF frame, or the FF frame that starts the transfer.
(define (start-tx cfg payload now)
  (define len (bytes-length payload))
  (when (zero? len)
    (error 'start-tx "cannot transmit an empty payload"))
  (when (> len (isotp-config-max-payload cfg))
    (error 'start-tx "payload of ~a byte(s) exceeds #:max-payload ~a" len (isotp-config-max-payload cfg)))
  (define initial (tx-state 'idle payload 0 1 0 now now 0 0 ""))
  (cond
    [(<= len (sf-capacity cfg))
     ;; On classic CAN the plain form carries up to 7 bytes; on CAN FD frames
     ;; (CAN_DL > 8) the escape form is mandatory.
     (define frame
       (if (config-fd? cfg)
           (sf-frame/escape payload)
           (sf-frame payload)))
     (values (struct-copy tx-state initial [phase 'done] [message "single frame"])
             (list (due-frame (tx-encode cfg frame) now)))]
    [else
     (define chunk (ff-first-chunk cfg len))
     (define frame
       (if (and (config-fd? cfg) (> len 4095))
           (ff-frame/escape len (subbytes payload 0 chunk))
           (ff-frame len (subbytes payload 0 chunk))))
     (values (struct-copy tx-state initial
                          [phase 'wait-fc]
                          [offset chunk]
                          [fc-wait-start now]
                          [message "first frame sent, waiting for flow control"])
             (list (due-frame (tx-encode cfg frame) now)))]))

;; Schedule and return every CF whose ready-at has arrived.  Shared by
;; tx-tick and the CTS branch of tx-flow-control.
(define (pump cfg st now)
  (if (eq? (tx-state-phase st) 'send-cf)
      (let ([payload (tx-state-payload st)]
            [total (bytes-length (tx-state-payload st))]
            [capacity (cf-chunk-size cfg)]
            ;; Pacing comes from the STmin the peer granted in its FC.
            [gap (/ (tx-state-granted-stmin-us st) 1000)]) ; in ms
        (let loop ([st st] [frames '()])
          (cond
            [(and (> (tx-state-block-left st) 0)
                  (<= (tx-state-next-ready-at st) now)
                  (< (tx-state-offset st) total))
             (define offset (tx-state-offset st))
             (define chunk (subbytes payload offset (min (+ offset capacity) total)))
             (define sn (tx-state-next-sn st))
             (define ready-at (tx-state-next-ready-at st))
             (define new-offset (+ offset (bytes-length chunk)))
             (define new-block (sub1 (tx-state-block-left st)))
             (define st1
               (struct-copy tx-state st
                            [offset new-offset]
                            [next-sn (modulo (+ sn 1) 16)]
                            [block-left new-block]
                            [next-ready-at (+ ready-at gap)]))
             (define st2
               (cond
                 [(>= new-offset total)
                  (struct-copy tx-state st1 [phase 'done] [message "payload delivered"])]
                 [(zero? new-block)
                  ;; Window exhausted: demand the next flow control.  N_Bs
                  ;; runs from the transmission time of the block's last CF.
                  (struct-copy tx-state st1
                               [phase 'wait-fc]
                               [fc-wait-start ready-at]
                               [message "block sent, waiting for flow control"])]
                 [else st1]))
             (loop st2 (cons (due-frame (tx-encode cfg (cf-frame sn chunk)) ready-at) frames))]
            [else
             (values st (reverse frames) (phase-outcome st))])))
      (values st '() (phase-outcome st))))

;; Feed a received flow-control frame into the machine.
(define (tx-flow-control cfg st fc now)
  (case (tx-state-phase st)
    [(wait-fc)
     (case (isotp-frame-flow-status fc)
       [(cts)
        (pump cfg
              (struct-copy tx-state st
                           [phase 'send-cf]
                           ;; BS = 0 means "unlimited window"; +inf.0 keeps
                           ;; the window arithmetic uniform.
                           [block-left (let ([bs (isotp-frame-block-size fc)])
                                         (if (zero? bs) +inf.0 bs))]
                           [next-ready-at now]
                           [granted-stmin-us (isotp-frame-stmin-us fc)]
                           [message "flow control received, sending block"])
              now)]
       [(wait)
        (define new-count (add1 (tx-state-wait-count st)))
        (if (> new-count (isotp-config-wait-limit cfg))
            (tx-fail st (format "received ~a FC.WAIT frame(s), exceeding #:wait-limit ~a"
                                new-count (isotp-config-wait-limit cfg)))
            (values (struct-copy tx-state st
                                 [wait-count new-count]
                                 [fc-wait-start now]
                                 [message "peer asked to wait"])
                    '()
                    (make-running-outcome "peer asked to wait")))]
       [(overflow)
        (tx-fail st "peer reported buffer overflow (FC.OVFLW)")])]
    [else
     (values st '() (make-running-outcome "flow control ignored: not waiting for one"))]))

;; Advance time: drain due frames and detect the N_Bs timeout.  `now` must
;; move monotonically forward.
(define (tx-tick cfg st now)
  (case (tx-state-phase st)
    [(wait-fc)
     (if (>= (- now (tx-state-fc-wait-start st)) (isotp-config-n-bs cfg))
         (tx-fail st "N_Bs timed out waiting for a flow control frame")
         (values st '() (phase-outcome st)))]
    [else (pump cfg st now)]))
