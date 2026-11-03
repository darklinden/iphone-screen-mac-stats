import Foundation

/// 内存已用。
///
/// 照搬自 stats/Modules/RAM/readers.swift：
/// - 总量 `host_info(HOST_BASIC_INFO)`：`:18-35`
/// - 已用公式：`:37-58`
///
/// 有一处**必须偏离**上游：上游用 `MemoryLayout<vm_statistics64_data_t>.offset(of: \.swapped_count)`
/// 算传给 `host_statistics64` 的字数，但当前 SDK 的 `vm_statistics64` 里没有 `swapped_count`
/// 这个字段（那是老 SDK 的写法），照抄编译不过。这里改成锚定现在的最后一个字段
/// `total_uncompressed_pages_in_compressor`，算出的字数同样是「结构体真正被填满的那部分」，
/// 且不会因为尾部 padding 多写 4 字节。
final class RAMReader {
    /// 物理内存总量，字节。
    let totalBytes: Int

    init() {
        let total = RAMReader.hostBasicInfoTotalSize()
        // protocol.md 里 mem.total_bytes 不是可空字段，没法用 null 表达「读不到」。
        // 与其报一个假的 0，不如在启动期就失败——这个调用实际上不会失败。
        guard total > 0 else {
            FileHandle.standardError.write(
                Data("读不到物理内存总量（host_info(HOST_BASIC_INFO) 失败），无法继续\n".utf8)
            )
            exit(1)
        }
        totalBytes = Int(total)
    }

    /// 已用内存，字节；读不到返回 nil。
    ///
    /// `used = active + inactive + speculative + wired + compressed - purgeable - external`
    func readUsed() -> Int? {
        var stats = vm_statistics64()
        var count = UInt32(
            (MemoryLayout<vm_statistics64_data_t>.offset(of: \.total_uncompressed_pages_in_compressor)!
             + MemoryLayout<UInt64>.size) / MemoryLayout<integer_t>.size
        )

        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHostPort, HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let active = Double(stats.active_count) * Double(vm_page_size)
        let speculative = Double(stats.speculative_count) * Double(vm_page_size)
        let inactive = Double(stats.inactive_count) * Double(vm_page_size)
        let wired = Double(stats.wire_count) * Double(vm_page_size)
        let compressed = Double(stats.compressor_page_count) * Double(vm_page_size)
        let purgeable = Double(stats.purgeable_count) * Double(vm_page_size)
        let external = Double(stats.external_page_count) * Double(vm_page_size)

        let used = active + inactive + speculative + wired + compressed - purgeable - external
        return Int(used)
    }

    /// stats/Modules/RAM/readers.swift:18-35
    private static func hostBasicInfoTotalSize() -> Double {
        var stats = host_basic_info()
        var count = UInt32(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_info(machHostPort, HOST_BASIC_INFO, $0, &count)
            }
        }

        return kerr == KERN_SUCCESS ? Double(stats.max_mem) : 0
    }
}
