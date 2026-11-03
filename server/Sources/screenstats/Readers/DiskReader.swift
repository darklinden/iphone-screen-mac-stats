import Foundation
import IOKit
// kIOBlockStorageDriverStatistics* 这几个宏在 IOKit 的 storage 子模块里，
// 光 import IOKit 带不进来。
import IOKit.storage

/// 内置启动盘的读 / 写速率。
///
/// 照搬自 stats/Modules/Disk/readers.swift：
/// - 取 `kIOBlockStorageDriverStatisticsKey` 并差分：`:248-257`
/// - 计数器类型校验与回绕处理：`:268-279`（本仓库落在 `Support/Counter.swift`）
///
/// 与上游的差别（共四处）：
/// - 只跟内置启动盘，上游遍历所有物理盘（docs/design.md 的「统计范围」）；
/// - 盘发现机制从上游的 `DADiskCopyIOMedia`（`Disk/readers.swift:235`）换成
///   `statfs("/")` + `IOBSDNameMatching`（同样是「统计范围」授权的）；
/// - 缓存 driver 句柄，读失败时重解析（上游没有）——睡眠 / 唤醒后 NVMe 重新枚举，
///   旧句柄会失效，不重解析就永久失明；
/// - 读不到时 `resetBaseline()`，让恢复后的第一帧重新走「没有前值 → null」的路径。
final class DiskReader {
    private var driver: io_registry_entry_t?
    private var previousRead: UInt64?
    private var previousWritten: UInt64?
    private var previousTime: UInt64?

    init() {
        driver = DiskReader.openBootDiskDriver()
    }

    /// 返回 bytes/s；第一次采样（没有前值）或读不到时为 nil。
    func read() -> (readBps: Int?, writeBps: Int?) {
        guard let counters = readCounters() else {
            // 读不到就报 null，**不能拿 0 冒充**（docs/protocol.md 的约定）。
            resetBaseline()
            return (nil, nil)
        }

        let time = monotonicNanoseconds()
        let elapsed = previousTime.map { time > $0 ? Double(time - $0) / 1_000_000_000 : 0 } ?? 0

        let read = counterActivity(
            counters.object(forKey: kIOBlockStorageDriverStatisticsBytesReadKey),
            previous: previousRead,
            elapsed: elapsed
        )
        let write = counterActivity(
            counters.object(forKey: kIOBlockStorageDriverStatisticsBytesWrittenKey),
            previous: previousWritten,
            elapsed: elapsed
        )

        // 计数器本身读不到（property 在、key 不在、或类型不对）时，
        // counterActivity 给的是 (nil, 0)——那个 0 是「没算出来」，不是「速率是 0」。
        guard let readBytes = read.bytes, let writeBytes = write.bytes else {
            resetBaseline()
            return (nil, nil)
        }

        previousRead = readBytes
        previousWritten = writeBytes
        previousTime = time

        guard elapsed > 0 else { return (nil, nil) }
        return (Int(clamping: read.rate), Int(clamping: write.rate))
    }

    /// 清掉差分基线，让恢复后的第一帧重新走一遍「没有前值 → null」的路径。
    private func resetBaseline() {
        previousRead = nil
        previousWritten = nil
        previousTime = nil
    }

    /// 读一次 `Statistics`。读不到时顺手重解析驱动句柄：
    /// 睡眠 / 唤醒后 NVMe 会重新枚举，旧句柄就废了，不重解析会永久失明。
    private func readCounters() -> NSDictionary? {
        if let driver = driver, let counters = DiskReader.statistics(of: driver) {
            return counters
        }

        guard let fresh = DiskReader.openBootDiskDriver() else { return nil }
        if let old = driver { IOObjectRelease(old) }
        driver = fresh

        return DiskReader.statistics(of: fresh)
    }

    private static func statistics(of driver: io_registry_entry_t) -> NSDictionary? {
        let property = IORegistryEntryCreateCFProperty(
            driver,
            kIOBlockStorageDriverStatisticsKey as CFString,
            kCFAllocatorDefault,
            0
        )
        return property?.takeRetainedValue() as? NSDictionary
    }

    /// 从根挂载点反查内置启动盘，再往上找到它的 IOBlockStorageDriver。
    private static func openBootDiskDriver() -> io_registry_entry_t? {
        guard let bsdName = bootDiskBSDName() else { return nil }

        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let media = IOIteratorNext(iterator)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }

        return getDeviceIOParent(media)
    }

    /// `statfs("/")` 的 `f_mntfromname` 形如 `/dev/disk3s1s1`，剥掉分区号得到整盘 `disk3`。
    private static func bootDiskBSDName() -> String? {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }

        let device = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }

        guard device.hasPrefix("/dev/") else { return nil }
        let name = String(device.dropFirst("/dev/".count))
        guard let range = name.range(of: "^disk[0-9]+", options: .regularExpression) else { return nil }
        return String(name[range])
    }
}
