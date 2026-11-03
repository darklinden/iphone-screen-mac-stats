import Foundation

/// CPU 总占用。
///
/// 照搬自 stats/Modules/CPU/readers.swift：
/// - 差分与比例计算：`:105-125`
/// - `hostCPULoadInfo()`：`:163-179`
final class CPUReader {
    private var previous = host_cpu_load_info()

    /// 返回 0.0–1.0 的总占用（system + user）；读不到返回 nil。
    ///
    /// 第一次调用时 `previous` 是全零，所以首帧读到的是**开机以来的平均占用**——
    /// 上游 stats 也是这个行为，照搬不改。
    func read() -> Double? {
        guard let info = hostCPULoadInfo() else { return nil }

        let userDiff = Double(info.cpu_ticks.0 &- previous.cpu_ticks.0)
        let sysDiff  = Double(info.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idleDiff = Double(info.cpu_ticks.2 &- previous.cpu_ticks.2)
        let niceDiff = Double(info.cpu_ticks.3 &- previous.cpu_ticks.3)
        let totalTicks = sysDiff + userDiff + niceDiff + idleDiff

        previous = info

        let system = sysDiff / totalTicks
        let user = userDiff / totalTicks
        let total = system + user

        // totalTicks 为 0 时上面两个除法是 NaN，stats 用 !isNaN 挡掉。
        return total.isNaN ? nil : total
    }

    /// stats/Modules/CPU/readers.swift:163-179
    private func hostCPULoadInfo() -> host_cpu_load_info? {
        let count = MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(count)
        var cpuLoadInfo = host_cpu_load_info()

        let result: kern_return_t = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: count) {
                host_statistics(machHostPort, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        if result != KERN_SUCCESS {
            return nil
        }

        return cpuLoadInfo
    }
}
