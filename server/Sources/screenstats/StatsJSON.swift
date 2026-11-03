import Foundation

/// `Sample` → [docs/protocol.md](../../../docs/protocol.md) 的嵌套 JSON。
///
/// 关键点：**可空字段必须编码成 `null`，而不是把 key 整个省掉**。Swift `Codable`
/// 的合成实现对 `Optional` 用 `encodeIfPresent`，nil 时 key 会消失，客户端就分不清
/// 「读不到」和「服务端没这个字段」。所以这里显式实现 `encode(to:)`，nil 一律 `encodeNil`。
enum StatsJSON {
    static func encode(_ sample: Sample) throws -> Data {
        try JSONEncoder().encode(StatsResponse(sample: sample))
    }
}

/// 只负责把扁平的 `Sample` 摊成协议要求的嵌套层级；字段名一个都不多、一个都不少。
private struct StatsResponse: Encodable {
    let sample: Sample

    private enum RootKey: String, CodingKey {
        case seq, ts, cpu, gpu, mem, disk, net
    }
    private enum CPUKey: String, CodingKey { case total }
    private enum GPUKey: String, CodingKey { case util }
    private enum MemKey: String, CodingKey {
        case totalBytes = "total_bytes"
        case usedBytes = "used_bytes"
    }
    private enum DiskKey: String, CodingKey {
        case readBps = "read_bps"
        case writeBps = "write_bps"
    }
    private enum NetKey: String, CodingKey {
        case iface
        case rxBps = "rx_bps"
        case txBps = "tx_bps"
    }

    func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: RootKey.self)
        try root.encode(sample.seq, forKey: .seq)
        try root.encode(sample.ts, forKey: .ts)

        var cpu = root.nestedContainer(keyedBy: CPUKey.self, forKey: .cpu)
        try cpu.encodeOrNull(sample.cpuTotal, forKey: .total)

        var gpu = root.nestedContainer(keyedBy: GPUKey.self, forKey: .gpu)
        try gpu.encodeOrNull(sample.gpuUtil, forKey: .util)

        var mem = root.nestedContainer(keyedBy: MemKey.self, forKey: .mem)
        // 内存总量是协议里唯一的非空 Int。
        try mem.encode(sample.memTotalBytes, forKey: .totalBytes)
        try mem.encodeOrNull(sample.memUsedBytes, forKey: .usedBytes)

        var disk = root.nestedContainer(keyedBy: DiskKey.self, forKey: .disk)
        try disk.encodeOrNull(sample.diskReadBps, forKey: .readBps)
        try disk.encodeOrNull(sample.diskWriteBps, forKey: .writeBps)

        var net = root.nestedContainer(keyedBy: NetKey.self, forKey: .net)
        try net.encode(sample.netIface, forKey: .iface)
        try net.encodeOrNull(sample.netRxBps, forKey: .rxBps)
        try net.encodeOrNull(sample.netTxBps, forKey: .txBps)
    }
}

private extension KeyedEncodingContainer {
    /// 有值编码值，nil 编码 `null`（而不是跳过这个 key）。
    mutating func encodeOrNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
