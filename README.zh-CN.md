# isotp — ISO 15765-2 (ISO-TP) transport over CAN, in pure Racket

[English](README.md) · **中文**

[![CI](https://github.com/turinglambdaai/isotp/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/isotp/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`isotp` 以纯 Racket 实现 **ISO 15765-2** 网络层——即 **ISO-TP** 或 **DoCAN**：帧编解码器（SF / FF / CF / FC，包括 CAN FD 的转义编码）、带流控与发送节奏控制的发送方状态机，以及带重组与溢出处理的接收方状态机。它是 UDS（ISO 14229）、OBD-II（ISO 15031）等汽车诊断协议之下的传输层。

状态机是纯函数式的、与传输无关的：每个事件函数接收一个时间戳并返回待发送的帧。可将其绑定到 SocketCAN、商用 CAN 接口卡、嵌入式 MCU 或测试替身——无 FFI，无系统依赖。

支持：

- 经典 CAN（8 字节帧）与 **CAN FD**（12–64 字节帧），包括单帧与首帧的扩展长度转义编码
- 全部七种寻址模式：`normal-11/29`、`extended-11/29`、`normal-fixed-29`、`mixed-11/29`，采用标准 29 位固定寻址标识符布局（`0x18DA0000` 物理 / `0x18DB0000` 功能，也可自定义前缀）
- 流控：块大小、STmin 节奏控制（ms 与 µs 两种形式）、可配置上限的 `FC.WAIT`、`FC.OVFLW`
- 超时 `N_Bs` / `N_Cr`、序列号检查、可配置填充、CAN FD 上最高 4294967295 字节的负载上限

## 安装

```
raco pkg install isotp
```

## 用法

先运行无需 CAN 硬件的单帧编解码往返示例。多帧传输还需要调用方驱动总线循环、单调时钟和流控；完整过程见[真实状态机回环测试](isotp/test/isotp-test.rkt)及 Scribble 的 `start-tx`、`rx-frame` API。

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

固定 29 位寻址（例如排放诊断所用）：

```racket
(define cfg (make-isotp-config #:addressing 'normal-fixed-29
                               #:target-address #x33   ; functional group
                               #:source-address #xF1)) ; tester
(isotp-tx-id cfg #t)  ; => #x18db33f1
```

完整 API（含帧编解码器与两个状态机）见[文档](isotp/scribblings/isotp.scrbl)（或 `raco docs isotp`）。

## 格式说明

- 帧类型半字节：`0x0` SF、`0x1` FF、`0x2` CF、`0x3` FC。在 CAN_DL > 8 的 CAN FD 帧上，单帧使用转义编码（`0x00 <len>`），超过 4095 字节的首帧将长度编码为 `0x10 0x00 <32-bit len>`。
- STmin（`0x00`–`0x7F` 为 ms，`0xF1`–`0xF9` 对应 100–900 µs）：保留值按 127 ms 处理，依据 ISO 15765-2 §9.2.4.2。
- `N_Bs` / `N_Cr` 默认为标准的 1000 ms，可配置。

## 局限

- 不包含 CAN 驱动绑定；标识符过滤与分发由调用方负责（`isotp-tx-id` / `isotp-rx-id` 辅助函数负责计算标识符）。
- 时序由调用方驱动，内部无线程。这使状态机保持确定性且极易测试。

## API、测试与兼容性

[Scribble API 手册](isotp/scribblings/isotp.scrbl)是帧编解码、
七种寻址模式、状态机返回值、流控和时间契约的权威来源；
单帧示例在文档构建期间真实执行。[独立入门示例](examples/quickstart.rkt)
不依赖 CAN 适配器。编解码器测试通过不等于完成实车/ECU 联调。

在已安装 Racket 的仓库根目录执行：

```sh
raco pkg install --auto --link .
raco test -p isotp
racket examples/quickstart.rkt
raco setup -l isotp --check-pkg-deps
```

CI 在 Linux、macOS、Windows 上执行检查。本包不提供 SocketCAN/驱动
绑定，也不负责真实时钟调度。反馈请在
[GitHub Issues](https://github.com/turinglambdaai/isotp/issues)
提交合成帧、寻址模式及 Racket 版本。

## 许可证

[MIT](LICENSE)
