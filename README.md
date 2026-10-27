# isotp — ISO 15765-2 (ISO-TP) transport over CAN, in pure Racket

**English** · [中文](README.zh-CN.md)

[![CI](https://github.com/turinglambdaai/isotp/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/isotp/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`isotp` implements the **ISO 15765-2** network layer — known as **ISO-TP** or
**DoCAN** — in pure Racket: the frame codec (SF / FF / CF / FC, including the
CAN FD escape encodings), a sender state machine with flow control and
pacing, and a receiver state machine with reassembly and overflow handling.
It is the transport layer beneath automotive diagnostics protocols such as
UDS (ISO 14229) and OBD-II (ISO 15031).

The state machines are pure and transport-agnostic: every event function
takes a timestamp and returns frames to transmit. Bind them to SocketCAN, a
commercial CAN interface, an embedded MCU, or a test double — there is no FFI
and no system dependency.

Supported:

- classic CAN (8-byte frames) and **CAN FD** (12–64-byte frames), including
  the extended-length escape encodings for single and first frames
- all seven addressing modes: `normal-11/29`, `extended-11/29`,
  `normal-fixed-29`, `mixed-11/29`, with the standard 29-bit fixed-addressing
  identifier layout (`0x18DA0000` physical / `0x18DB0000` functional, or your
  own prefix)
- flow control: block size, STmin pacing (ms and µs forms), `FC.WAIT` with a
  configurable limit, `FC.OVFLW`
- timeouts `N_Bs` / `N_Cr`, sequence-number checking, configurable padding,
  payload limits up to 4294967295 bytes on CAN FD

## Installation

```
raco pkg install isotp
```

## Usage

Start with a real, transport-free single-frame encode/decode round trip.
Multi-frame transfer additionally requires a caller-driven bus loop, clock
and flow-control handling; see the [full test loopback](isotp/test/isotp-test.rkt)
and the Scribble API for `start-tx`, `rx-frame` and timeouts.

```racket
#lang racket/base
(require isotp)

(define payload #"hello")
(define encoded (isotp-frame->bytes (sf-frame payload)))
;; Single-frame PCI length byte followed by data.
(unless (bytes=? encoded (bytes #x05 104 101 108 108 111))
  (error 'isotp-example "wrong single-frame bytes"))
(unless (bytes=? (isotp-frame-data (bytes->isotp-frame encoded)) payload)
  (error 'isotp-example "round trip failed"))
```

Fixed 29-bit addressing (as used by emissions diagnostics, for example):

```racket
(define cfg (make-isotp-config #:addressing 'normal-fixed-29
                               #:target-address #x33   ; functional group
                               #:source-address #xF1)) ; tester
(isotp-tx-id cfg #t)  ; => #x18db33f1
```

See [the documentation](isotp/scribblings/isotp.scrbl) (or `raco docs isotp`) for the full
API, including the frame codec and both state machines.

## Format notes

- Frame type nibbles: `0x0` SF, `0x1` FF, `0x2` CF, `0x3` FC. On CAN FD
  frames with CAN_DL > 8, single frames use the escape encoding
  (`0x00 <len>`), and first frames above 4095 bytes encode the length as
  `0x10 0x00 <32-bit len>`.
- STmin (`0x00`–`0x7F` ms, `0xF1`–`0xF9` = 100–900 µs): reserved values are
  treated as 127 ms, per ISO 15765-2 §9.2.4.2.
- `N_Bs` / `N_Cr` default to the standard 1000 ms and are configurable.

## Limitations

- No CAN driver binding is included; identifier filtering and dispatch are
  the caller's job (the `isotp-tx-id` / `isotp-rx-id` helpers compute the
  identifiers).
- Timing is caller-driven; there is no internal thread. This keeps the
  machines deterministic and trivially testable.

## API, tests and compatibility

The [Scribble reference](isotp/scribblings/isotp.scrbl) is the authoritative
description of the frame codec, seven address modes, state-machine returns,
flow control and timing contracts. Its new single-frame example is evaluated
as part of the document build. Run the
[standalone quickstart](examples/quickstart.rkt) without a CAN interface.
Do not confuse a passed codec smoke test with a real CAN/ECU qualification.

From the package root (Racket installed):

```sh
raco pkg install --auto --link "$(pwd)"
raco test -p isotp
racket examples/quickstart.rkt
raco setup -l isotp --check-pkg-deps
```

The existing CI matrix tests Linux, macOS and Windows. No SocketCAN/driver
binding or wall-clock scheduling is part of the package. Report issues with
synthetic frame bytes, the selected addressing mode and Racket version at
[GitHub Issues](https://github.com/turinglambdaai/isotp/issues).

## License

[MIT](LICENSE)
