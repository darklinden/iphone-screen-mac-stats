import Foundation

/// 指定网卡的收 / 发速率。
///
/// 照搬自 stats/Modules/Net/readers.swift:704-739 的 `getBytesInfo()`：
/// `sysctl(NET_RT_IFLIST2)` 走一遍路由消息表，找到 `ifm_index` 匹配的那条
/// `RTM_IFINFO2`，读 `ifi_ibytes`（收）/ `ifi_obytes`（发）。
///
/// 与上游的差别：上游同样只读一个接口（`getBytesInfo()` 里是 `self.interfaceID`，
/// 调用点在 `:359`），只是那个接口运行时可切换；这里在构造时由 `--iface` 固定
/// （默认 `en0`），见 docs/design.md 的「统计范围」。
///
/// `read()`（本文件 `:29-44`）不是照搬上游 `read()`（`Net/readers.swift:282-333`）：
/// 上游那里还有负值钳制（`:311-312`）与 `maxDelta` 跳变保护（`:314-323`），
/// 本仓库**都没搬**，差分只走 `Support/Counter.swift` 的回绕处理。这是有意的取舍——
/// docs/design.md 的「差分与速率」只规定了回绕处理。
final class NetReader {
    let iface: String

    private var previousRx: UInt64?
    private var previousTx: UInt64?
    private var previousTime: UInt64?

    init(iface: String) {
        self.iface = iface
    }

    /// 返回 bytes/s；第一次采样（没有前值）或读不到时为 nil。
    func read() -> (rxBps: Int?, txBps: Int?)? {
        guard let counters = readCounters() else { return nil }

        let time = monotonicNanoseconds()
        let elapsed = previousTime.map { time > $0 ? Double(time - $0) / 1_000_000_000 : 0 } ?? 0

        let rx = counterActivity(NSNumber(value: counters.rx), previous: previousRx, elapsed: elapsed)
        let tx = counterActivity(NSNumber(value: counters.tx), previous: previousTx, elapsed: elapsed)

        previousRx = rx.bytes
        previousTx = tx.bytes
        previousTime = time

        guard elapsed > 0 else { return (nil, nil) }
        return (Int(clamping: rx.rate), Int(clamping: tx.rate))
    }

    /// stats/Modules/Net/readers.swift:704-739
    private func readCounters() -> (rx: UInt64, tx: UInt64)? {
        let index = if_nametoindex(iface)
        guard index != 0 else { return nil }

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= size {
            var header = if_msghdr()
            buffer.withUnsafeBytes { src in
                _ = memcpy(&header, src.baseAddress?.advanced(by: offset), MemoryLayout<if_msghdr>.size)
            }
            guard header.ifm_msglen > 0 else { return nil }

            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size {
                var header2 = if_msghdr2()
                buffer.withUnsafeBytes { src in
                    _ = memcpy(&header2, src.baseAddress?.advanced(by: offset), MemoryLayout<if_msghdr2>.size)
                }
                if UInt32(header2.ifm_index) == index {
                    return (rx: header2.ifm_data.ifi_ibytes, tx: header2.ifm_data.ifi_obytes)
                }
            }

            offset += Int(header.ifm_msglen)
        }

        return nil
    }
}
