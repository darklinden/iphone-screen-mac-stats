import Foundation
import IOKit
// kIOAcceleratorClassName 在 IOKit 的 graphics 子模块里。
import IOKit.graphics

/// GPU 利用率。
///
/// 照搬自 stats/Modules/GPU/reader.swift：
/// - 遍历 `kIOAcceleratorClassName`、取 `PerformanceStatistics`：`:102-117`
/// - 利用率取值与兜底：`:139`
///
/// 上游是 `stats["Device Utilization %"] as? Int ?? stats["GPU Activity(%)"] as? Int ?? nil`——
/// 不同机型的 key 名不一样，所以两级都要留。
final class GPUReader {
    /// 返回 0.0–1.0 的设备利用率；读不到返回 nil。
    ///
    /// 上游给的是 0–100 的整数，这里换算成协议的 0.0–1.0。
    func read() -> Double? {
        guard let accelerators = fetchIOService(kIOAcceleratorClassName) else { return nil }

        for accelerator in accelerators {
            guard let stats = accelerator["PerformanceStatistics"] as? [String: Any] else { continue }

            let utilization: Int? = stats["Device Utilization %"] as? Int ?? stats["GPU Activity(%)"] as? Int ?? nil
            if let utilization {
                // 上游 GPU/reader.swift:213-217 有「>100 就钳到 100」的保护，照搬；
                // 下界是额外补的，保证落在 protocol.md 写的 0.0–1.0 里。
                return min(1.0, max(0.0, Double(utilization) / 100.0))
            }
        }

        return nil
    }
}
