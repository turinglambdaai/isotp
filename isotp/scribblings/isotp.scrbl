#lang scribble/doc

@(require scribble/manual
          scribble/eval
          (for-label isotp
                     racket/base
                     racket/contract))

@(define (make-eval) (make-base-eval #:lang 'racket/base '(isotp)))

@title{isotp: ISO 15765-2 (ISO-TP) transport over CAN}
@author{@(author+email "turinglambdaai" "turinglambdaai@users.noreply.github.com")}

@defmodule[isotp]

This package implements the @hyperlink["https://www.iso.org/standard/67248.html"]{ISO 15765-2}
network layer — known as @deftech{ISO-TP} or @deftech{DoCAN} — in pure Racket.
ISO-TP carries multi-packet messages over CAN bus frames, and is the transport
beneath automotive diagnostics protocols such as Unified Diagnostic Services
(UDS, ISO 14229) and OBD-II (ISO 15031).

The implementation is a @emph{codec plus state machines}; it deliberately does
not talk to any CAN driver itself:

@itemlist[
 @item{@racket[bytes->isotp-frame] and @racket[isotp-frame->bytes] encode and
  decode the four protocol data units (SF, FF, CF, FC), including the CAN FD
  escape encodings.}
 @item{The sender state machine segments a payload, honors the peer's flow
  control (block size, @tt{STmin} pacing, @tt{FC.WAIT}) and times out
  @tt{N_Bs}.}
 @item{The receiver state machine reassembles payloads, emits flow control,
  answers overflow with @tt{FC.OVFLW} and times out @tt{N_Cr}.}
]

Because both machines are pure — every event function takes a timestamp and
returns frames to transmit — they are trivial to unit-test, deterministic to
replay, and independent of the CAN binding (SocketCAN, a Vector bus, an
embedded MCU, or a test double).  Both classic CAN (8-byte frames) and
@deftech{CAN FD} (12–64-byte frames) are supported, as are all seven
addressing modes of the standard.

@section[#:tag "quickstart"]{Quick start}

A sender and a receiver meet over an idealized bus: every @racket[due-frame]
the sender emits is fed to the receiver, and every flow-control frame the
receiver emits goes back to the sender.  Timestamps are milliseconds on any
monotonic clock.

@racketblock[
(require isotp)

(define cfg (make-isotp-config #:block-size 8 #:stmin-ms 10))

;; — sender side —
(define-values (tx frames) (start-tx cfg #"hello ISO-TP world, this is long" 0))
;; transmit each frame after its due-frame-ready-at time ...

;; — receiver side —
(define rx (make-rx-state cfg))
(define-values (rx2 payload fc o) (rx-frame cfg rx (due-frame-bytes (car frames)) 0))
;; fc holds the FC.CTS frame to transmit; o's status is 'running
]

@section{Configuration}

@defproc[(make-isotp-config [#:addressing addressing
                             (or/c 'normal-11 'normal-29 'normal-fixed-29
                                   'extended-11 'extended-29 'mixed-11 'mixed-29)
                             'normal-11]
                            [#:tx-id tx-id (or/c #f exact-nonnegative-integer?) #f]
                            [#:rx-id rx-id (or/c #f exact-nonnegative-integer?) #f]
                            [#:target-address target-address (or/c #f (integer-in 0 255)) #f]
                            [#:source-address source-address (or/c #f (integer-in 0 255)) #f]
                            [#:address-extension address-extension (or/c #f (integer-in 0 255)) #f]
                            [#:physical-id physical-id (or/c #f exact-nonnegative-integer?) #f]
                            [#:functional-id functional-id (or/c #f exact-nonnegative-integer?) #f]
                            [#:frame-size frame-size (integer-in 8 64) 8]
                            [#:block-size block-size (integer-in 0 255) 8]
                            [#:stmin-ms stmin-ms (or/c #f (integer-in 0 127)) #f]
                            [#:stmin-us stmin-us (or/c #f (integer-in 100 900)) #f]
                            [#:n-bs n-bs real? 1000]
                            [#:n-cr n-cr real? 1000]
                            [#:wait-limit wait-limit exact-nonnegative-integer? 0]
                            [#:max-payload max-payload exact-nonnegative-integer? 4095]
                            [#:rx-buffer-size rx-buffer-size exact-nonnegative-integer? 4095]
                            [#:tx-padding tx-padding (or/c #f (integer-in 0 255)) #f]
                            [#:rx-padding rx-padding (or/c #f (integer-in 1 64)) #f])
         isotp-config?]{

Creates a connection configuration.  One value describes one ISO-TP
connection and is shared by the sender and receiver machines.

@itemlist[
 @item{@racket[#:addressing] — the addressing mode.  @tt{normal-*} spend no
  payload bytes on addressing; @tt{extended-*} spend the first payload byte on
  the target address; @tt{normal-fixed-29} and @tt{mixed-29} encode addresses
  in the 29-bit identifier (see @secref{addressing}); @tt{mixed-*}
  additionally carry an address-extension byte.}
 @item{@racket[#:frame-size] — the transmitted CAN_DL: @racket[8] for classic
  CAN, one of @racket['(12 16 20 24 32 48 64)] for CAN FD.
  @racket[config-fd?] reports whether the configuration uses CAN FD.}
 @item{@racket[#:block-size] and @racket[#:stmin-ms]/@racket[#:stmin-us] —
  the BS and STmin values @emph{this node} grants as a receiver when it sends
  @tt{FC.CTS}.  A sender's pacing comes from the STmin the @emph{peer} grants.
  STmin may be given in milliseconds (0–127) or microseconds (100–900, in
  100 µs steps).}
 @item{@racket[#:n-bs] / @racket[#:n-cr] — timeouts in milliseconds for
  waiting for a flow-control frame (N_Bs) and for the next consecutive frame
  (N_Cr).  The standard value is 1000 ms.}
 @item{@racket[#:wait-limit] — how many consecutive @tt{FC.WAIT} frames the
  sender tolerates.  The default @racket[0] rejects @tt{FC.WAIT} outright;
  set a positive limit (e.g. @racket[32]) when the peer is allowed to stall.}
 @item{@racket[#:max-payload] — accepted by @racket[start-tx].  Classic CAN
  caps at 4095; CAN FD may go up to @racket[(sub1 (expt 2 32))] using the
  escaped first-frame encoding.}
 @item{@racket[#:rx-buffer-size] — first frames declaring more than this are
  answered with @tt{FC.OVFLW}.}
 @item{@racket[#:tx-padding] — a fill byte; every transmitted frame is padded
  up to @racket[#:frame-size].  @racket[#:rx-padding] — the minimum CAN_DL
  accepted on reception (frames shorter than this are ignored).}
]
}

@defthing[isotp-config? predicate?]{

Predicate for configuration values.  An accessor is provided for every
configuration field (e.g. @racketid[isotp-config-addressing],
@racketid[isotp-config-frame-size]), plus the @racket[config-fd?],
@racket[config-prefix-size] and @racket[config-data-capacity] helpers below.
}

@defproc[(config-fd? [cfg isotp-config?]) boolean?]{

Reports whether the configuration selects CAN FD frame sizes
(@racket[#:frame-size] greater than @racket[8]).
}

@defproc[(config-prefix-size [cfg isotp-config?]) (integer-in 0 1)]{

Number of payload bytes spent on addressing (one for extended and mixed
modes, zero otherwise).
}

@defproc[(config-data-capacity [cfg isotp-config?]) exact-nonnegative-integer?]{

Payload bytes available per full frame: the frame's CAN_DL minus the
addressing prefix.
}

@section[#:tag "addressing"]{Addressing helpers}

@defproc[(isotp-tx-id [cfg isotp-config?] [functional? boolean? #f])
         exact-nonnegative-integer?]{

The arbitration identifier this node transmits on; @racket[functional?]
selects the 1-to-n identifier.  For @tt{normal-fixed-29} and @tt{mixed-29}
this composes the standard-mandated 29-bit layout: physical prefix
@racket[#x18DA0000] / functional @racket[#x18DB0000] (mixed: @racket[#x18CE0000]
/ @racket[#x18CD0000]), then the target address in bits 15–8 and the source
address in bits 7–0.  Custom prefixes can be installed with
@racket[@#:physical-id] / @racket[@#:functional-id] (bits 28–16).
}

@defproc[(isotp-rx-id [cfg isotp-config?] [functional? boolean? #f])
         exact-nonnegative-integer?]{

The identifier this node receives on (prefix, then source address in bits
15–8 and target address in bits 7–0).
}

@section{Frame codec}

@defstruct*[isotp-frame ([type symbol?]
                         [data (or/c #f bytes?)]
                         [flow-status (or/c #f symbol?)]
                         [block-size (or/c #f (integer-in 0 255))]
                         [stmin-us (or/c #f real?)]
                         [raw-stmin (or/c #f (integer-in 0 255))]
                         [sequence-number (or/c #f exact-nonnegative-integer?)]
                         [escape? boolean?]
                         [can-dl exact-nonnegative-integer?])]{

One protocol data unit.  @racket[type] is @racket['sf], @racket['ff],
@racket['cf] or @racket['fc].  For FC frames, @racket[flow-status] is
@racket['cts], @racket['wait] or @racket['overflow], and @racket[stmin-us] is
the decoded separation time.  For CF frames @racket[sequence-number] is the
4-bit sequence number; for FF frames it is the @emph{total message length}.
@racket[escape?] marks the CAN FD extended-length encodings.
}

@defproc[(bytes->isotp-frame [payload bytes?] [prefix-size exact-nonnegative-integer? 0])
         isotp-frame?]{

Decodes one CAN payload (everything after the identifier).  Any addressing
prefix has been counted in @racket[prefix-size] and is skipped.  Trailing
padding is accepted; a PCI that claims more bytes than the frame carries
raises @racket[exn:fail].  When the frame's CAN_DL exceeds 8, a single frame
must use the escape encoding.
}

@defproc[(isotp-frame->bytes [frame isotp-frame?]
                             [#:fill fill exact-nonnegative-integer? 0]
                             [#:pad-byte pad-byte (integer-in 0 255) 0])
         bytes?]{

Encodes a frame, padding up to @racket[fill] bytes with @racket[pad-byte]
(the natural size is used when @racket[fill] is smaller).
}

@defproc[(sf-frame [data bytes?]) isotp-frame?]{Plain single frame (1–7 payload bytes).}

@defproc[(sf-frame/escape [data bytes?]) isotp-frame?]{Escaped single frame (1–62 bytes), mandatory on CAN FD frames with CAN_DL > 8.}

@defproc[(ff-frame [total (integer-in 1 4095)] [data bytes?]) isotp-frame?]{First frame with the 12-bit length encoding.}

@defproc[(ff-frame/escape [total (integer-in 4096 4294967295)] [data bytes?]) isotp-frame?]{First frame with the 32-bit escape length.}

@defproc[(cf-frame [sn (integer-in 0 15)] [data bytes?]) isotp-frame?]{Consecutive frame with sequence number @racket[sn].}

@defproc[(fc-frame [flow-status (or/c 'cts 'wait 'overflow)]
                   [block-size (integer-in 0 255)]
                   [stmin-us (integer-in 0 900000)])
         isotp-frame?]{Flow-control frame.}

@defproc[(stmin-byte->us [b (integer-in 0 255)]) exact-nonnegative-integer?]{
Decodes a wire STmin byte to microseconds.  Follows ISO 15765-2 §9.2.4.2:
@tt{0x00–0x7F} is 0–127 ms, @tt{0xF1–0xF9} is 100–900 µs, and @emph{reserved
values are treated as 127 ms}.}

@defproc[(stmin-us->byte [us (integer-in 0 900000)]) (integer-in 0 255)]{
Encodes microseconds to a STmin byte: whole milliseconds up to 127 ms, or
100–900 µs in 100 µs steps; anything else raises @racket[exn:fail].}

@section{Sending}

@defproc[(start-tx [cfg isotp-config?] [payload bytes?] [now real?])
         (values tx-state? (listof due-frame?))]{

Begins transmitting @racket[payload].  Returns either a single frame (SF) or
the first frame (FF) of a multi-frame transfer; in the latter case the state
waits for flow control.
}

@defproc[(tx-flow-control [cfg isotp-config?] [st tx-state?] [fc isotp-frame?] [now real?])
         (values tx-state? (listof due-frame?) outcome?)]{

Feeds a received flow-control frame to the sender.  @tt{FC.CTS} releases the
next block of consecutive frames (paced by the STmin granted in @racket[fc]);
@tt{FC.WAIT} is tolerated up to @racket[@#:wait-limit] times; @tt{FC.OVFLW}
fails the connection.
}

@defproc[(tx-tick [cfg isotp-config?] [st tx-state?] [now real?])
         (values tx-state? (listof due-frame?) outcome?)]{

Advances time: releases consecutive frames whose @racket[due-frame-ready-at]
has passed and raises an @tt{N_Bs} timeout error when no flow control arrives
in time.  Call this from a timer.
}

@defstruct*[tx-state ([phase symbol?] [payload bytes?] [offset real?]
                      [next-sn (integer-in 0 15)] [block-left real?]
                      [next-ready-at real?] [fc-wait-start real?]
                      [wait-count exact-nonnegative-integer?]
                      [granted-stmin-us real?] [message string?])]{

Sender progress.  @racket[phase] is @racket['idle], @racket['wait-fc],
@racket['send-cf], @racket['done] or @racket['error].
}

@section{Receiving}

@defproc[(make-rx-state [cfg isotp-config?]) rx-state?]{

Creates an idle receiver state.
}

@defproc[(rx-frame [cfg isotp-config?] [st rx-state?] [payload bytes?] [now real?])
         (values rx-state? (or/c #f bytes?) (or/c #f due-frame?) outcome?)]{

Feeds one received CAN payload (identifier excluded, addressing prefix
included) to the receiver.  Returns the new state, a completed payload when a
message finished arriving, flow-control bytes to transmit when one is due
(CTS on first frames and at block boundaries, OVFLW on overflow), and an
outcome.  A single frame interrupts an ongoing reception; a retransmitted
first frame is ignored; a wrong sequence number or an @tt{N_Cr} timeout fails
the connection.
}

@defproc[(rx-tick [cfg isotp-config?] [st rx-state?] [now real?])
         (values rx-state? (or/c #f bytes?) (or/c #f due-frame?) outcome?)]{

Advances time and detects the @tt{N_Cr} timeout.  Call this from a timer.
}

@defstruct*[rx-state ([phase symbol?] [total (or/c #f exact-nonnegative-integer?)]
                      [chunks (listof bytes?)] [received real?]
                      [expected-sn (integer-in 0 15)] [cf-since-fc exact-nonnegative-integer?]
                      [last-activity real?] [message string?])]{

Receiver progress.  @racket[phase] is @racket['idle], @racket['wait-cf] or
@racket['error].
}

@section{Results and due frames}

@defstruct*[outcome ([status symbol?] [message string?])]{

Result of a state-machine step: @racket['running], @racket['done] or
@racket['error], with a human-readable @racket[message].
}

@defstruct*[due-frame ([bytes bytes?] [ready-at real?])]{

A frame to put on the bus, not before the timestamp @racket[ready-at]
(milliseconds, same clock as the @racket[now] arguments).
}

@section{Caveats and roadmap}

@itemlist[
 @item{Timeouts and pacing are driven by the caller's timestamps; there is no
  internal thread.  Bind the machines to your scheduler or CAN driver loop.}
 @item{The library does not filter arbitration identifiers — register the ids
  from @racket[isotp-tx-id] / @racket[isotp-rx-id] with your CAN driver and
  dispatch incoming payloads by identifier.}
 @item{Roadmap: a convenience event-loop adapter, J1939-style fixed-address
  table helpers, and property-based fuzzing of the codec.}
]
