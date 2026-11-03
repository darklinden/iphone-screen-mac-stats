# iphone-screen-stats

把常亮、长期插电的 iPhone SE2 变成 Mac mini 的状态副屏。仓库里有两个进程：Mac 上的 Swift 采集**服务端**（`server/`），iPhone 上的原生 iOS **客户端**（`ios/`）。两者之间只有一条 HTTP 轮询契约。术语见 [GLOSSARY.md](GLOSSARY.md)。

## 按任务找文档

| 你要做的事 | 读这个 |
|---|---|
| 改采集逻辑、加一个指标 | [docs/design.md](docs/design.md) 的「采集实现映射」 |
| 改线协议、加字段 | [docs/protocol.md](docs/protocol.md) |
| 改界面布局、动翻页时钟代码 | [docs/design.md](docs/design.md) 的「界面规格」 |
| 动手写代码 | [docs/roadmap.md](docs/roadmap.md) |
| 问某个决定为什么是这样 | [docs/adr/](docs/adr/) |

## 硬约束

- 客户端 deployment target **iOS 15.0**；目标设备 iPhone SE2 / iOS 15.8.8；**只支持横屏**。
- 客户端 bundle identifier 是 `com.darklinden.screenstats`，用**免费开发者账号**签名，provisioning **每 7 天过期**。续签依赖 **iPhone 长期插在 Mac mini 的 USB 口上**（iOS 15 不支持 `devicectl` 无线安装）。动 bundle id 或签名配置之前先读 [ADR-0001](docs/adr/0001-native-ios-app-over-web.md)。
- 服务端**只统计 `en0` 与内置启动盘**，其它接口与卷不进读数。
- 采样固定 **1 Hz**，传输固定 **HTTP 轮询**。
- 服务端**零第三方依赖**，HTTP 层用 `Network.framework` 手写。
- 百分比一律 0.0–1.0 的 Double，速率一律 bytes/s 的 Int，读不到用 `null`。细节在 [docs/protocol.md](docs/protocol.md)。
- 采集逻辑从 exelban/stats 的 reader **逐段照搬**，连同原注释与出处行号一起搬，方便日后对照上游。映射表在 [docs/design.md](docs/design.md)。

## 参考项目

两个仓库都只做参考，所有改动都发生在本仓库内：

- `/opt/home/Github/stats/` — exelban/stats。服务端采集逻辑照搬自它的 `Modules/*/reader*.swift`（注意 GPU 是单数的 `GPU/reader.swift`）。
- `/opt/home/Github/flipClock/` — 你自己的翻页时钟 iOS App。客户端以它为起点：把需要的文件**复制**进 `ios/` 之后再改。

## 命令

代码落地后，仓库根的 `Makefile` 是唯一命令入口（见 [docs/roadmap.md](docs/roadmap.md) 的 M0）。在那之前没有可跑的命令。
