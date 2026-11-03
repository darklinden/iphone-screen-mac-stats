import Foundation

/// [docs/protocol.md](../../../docs/protocol.md) 响应体的 `Codable` 模型。
///
/// - 所有**指标字段都是 optional**：协议允许 `null`，且「读不到」与 `0` 是两回事。
/// - `Codable` 的合成实现天然忽略未知 key，满足协议「新增字段一律增量添加，
///   客户端必须容忍未知字段」的约定，不需要额外处理。
struct StatsResponse: Decodable {
    /// 服务端每次采样 +1；服务端重启后归零。客户端用它判失联与停更。
    let seq: Int
    /// 服务端墙钟，仅供参考——客户端不用它做判据，避免两机时钟偏差。
    let ts: Double?
    let cpu: StatsCPU?
    let gpu: StatsGPU?
    let mem: StatsMem?
    let disk: StatsDisk?
    let net: StatsNet?
}

struct StatsCPU: Decodable {
    /// 0.0–1.0
    let total: Double?
}

struct StatsGPU: Decodable {
    /// 0.0–1.0
    let util: Double?
}

struct StatsMem: Decodable {
    let totalBytes: Int?
    let usedBytes: Int?

    private enum CodingKeys: String, CodingKey {
        case totalBytes = "total_bytes"
        case usedBytes = "used_bytes"
    }
}

struct StatsDisk: Decodable {
    /// bytes/s
    let readBps: Int?
    /// bytes/s
    let writeBps: Int?

    private enum CodingKeys: String, CodingKey {
        case readBps = "read_bps"
        case writeBps = "write_bps"
    }
}

struct StatsNet: Decodable {
    let iface: String?
    /// bytes/s
    let rxBps: Int?
    /// bytes/s
    let txBps: Int?

    private enum CodingKeys: String, CodingKey {
        case iface
        case rxBps = "rx_bps"
        case txBps = "tx_bps"
    }
}
