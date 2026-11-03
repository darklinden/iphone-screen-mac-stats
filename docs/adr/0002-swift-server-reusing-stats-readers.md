# 服务端用 Swift 写，采集逻辑照搬 exelban/stats

采集这几项指标需要直接调 Mach 与 IOKit：`host_statistics`、`host_statistics64`、`IOServiceMatching(kIOAcceleratorClassName)`、`IORegistryEntryCreateCFProperty(kIOBlockStorageDriverStatisticsKey)`、`sysctl(NET_RT_IFLIST2)`。

`/opt/home/Github/stats/`（exelban/stats）是一份 Swift 的、已经跑了多年的实现，指标全有，**且全部不需要 sudo**（全仓库没有 `powermetrics`）。换别的语言意味着用 cgo / ctypes 把这套绑定重新做一遍，还要重新试出 Apple Silicon 上 `IOAccelerator` 的私有 key 名。

## 只搬 reader，不 fork 整个工程

stats 是 123 个 `.swift` 文件、47024 行的完整 AppKit 应用，它的底座（`Kit/module/`）与我们的需求无关。我们只从 `Modules/*/reader*.swift` 里把采集函数照抄进 `server/`（GPU 是单数的 `GPU/reader.swift`），保留原注释与「文件:行号」出处，方便日后对照上游。映射表见 [design.md](../design.md)。

## 附带决定：零第三方依赖

HTTP 层用 `Network.framework` 的 `NWListener` 手写最小 HTTP/1.1（只处理一个 `GET`，`Connection: close`，不实现 keep-alive）。1 Hz 一个客户端的量级下，这比引入 SwiftNIO 的依赖树更划算。
