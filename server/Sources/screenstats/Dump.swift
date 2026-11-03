import Foundation

/// `--dump` 的人类可读输出。只在终端验证采集对不对时用，不是协议的一部分。
enum Dump {
    static func line(for sample: Sample) -> String {
        let cpu = percent(sample.cpuTotal)
        let gpu = percent(sample.gpuUtil)
        let mem = memory(used: sample.memUsedBytes, total: sample.memTotalBytes)

        return """
        seq \(pad(String(sample.seq), 6))  \
        CPU \(cpu)  GPU \(gpu)  MEM \(mem)  \
        DISK R \(rate(sample.diskReadBps)) W \(rate(sample.diskWriteBps))  \
        NET \(sample.netIface) ↓ \(rate(sample.netRxBps)) ↑ \(rate(sample.netTxBps))
        """
    }

    /// 读不到显示 `--`，不显示 0（docs/protocol.md 的约定）。
    private static func percent(_ value: Double?) -> String {
        guard let value else { return "    --" }
        return String(format: "%5.1f%%", value * 100)
    }

    /// 内存按 1024 进制，这样 16 GB 的机器显示 16.0 GB。
    private static func memory(used: Int?, total: Int) -> String {
        let gb = 1024.0 * 1024 * 1024
        guard let used else { return "--/\(String(format: "%.1f", Double(total) / gb)) GB" }
        return String(format: "%.1f/%.1f GB", Double(used) / gb, Double(total) / gb)
    }

    /// 速率按 1000 进制换算，保留 1 位小数。客户端要跟这里保持一致。
    private static func rate(_ bytesPerSecond: Int?) -> String {
        guard let bytesPerSecond else { return "       --" }
        let value = Double(bytesPerSecond)

        if value < 1_000 { return String(format: "%6.1f B/s", value) }
        if value < 1_000_000 { return String(format: "%6.1f KB/s", value / 1_000) }
        if value < 1_000_000_000 { return String(format: "%6.1f MB/s", value / 1_000_000) }
        return String(format: "%6.1f GB/s", value / 1_000_000_000)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }
}
