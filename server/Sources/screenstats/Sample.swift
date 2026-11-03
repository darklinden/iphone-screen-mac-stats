import Foundation

/// 一次采样的结果。字段名与 [docs/protocol.md](../../../docs/protocol.md) 一一对应，
/// 一个字段都不多、一个字段都不少。
///
/// 读不到一律 `nil`，序列化成 JSON 时是 `null`——**不要用 0 冒充**。
struct Sample {
    /// 每次采样 +1，服务端重启后归零。
    var seq: Int
    /// 服务端墙钟，仅供参考。
    var ts: Double

    var cpuTotal: Double?

    var gpuUtil: Double?

    var memTotalBytes: Int
    var memUsedBytes: Int?

    var diskReadBps: Int?
    var diskWriteBps: Int?

    var netIface: String
    var netRxBps: Int?
    var netTxBps: Int?
}
