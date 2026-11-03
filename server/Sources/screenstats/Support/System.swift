import Foundation
import IOKit
import IOKit.storage

// 这一层是 exelban/stats 里 `Kit/helpers.swift` 与 `Modules/Disk/readers.swift` 的
// 工具函数，逐段照搬，只去掉日志与 UI 相关的部分。出处行号写在每个函数上方。

/// stats/Kit/helpers.swift:21
let machHostPort: mach_port_t = mach_host_self()

/// stats/Kit/helpers.swift:783-804
func fetchIOService(_ name: String) -> [NSDictionary]? {
    var iterator: io_iterator_t = io_iterator_t()
    var obj: io_registry_entry_t = 1
    var list: [NSDictionary] = []

    let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator)
    if result != kIOReturnSuccess {
        return nil
    }

    while obj != 0 {
        obj = IOIteratorNext(iterator)
        if let props = getIOProperties(obj) {
            list.append(props)
        }
        IOObjectRelease(obj)
    }
    IOObjectRelease(iterator)

    return list.isEmpty ? nil : list
}

/// stats/Kit/helpers.swift:806-817
///
/// 偏离上游：上游写的是 `defer { properties?.release() }` + `takeUnretainedValue()`。
/// `Create` 给的是 +1，defer 花掉这 +1，而 `takeUnretainedValue()` 不补 retain——
/// 当前只是靠 ARC 在 return 处恰好补了一次 retain 才不悬垂。这里改成
/// `takeRetainedValue()`，与 +1 正好配平，不依赖那个巧合。
func getIOProperties(_ entry: io_registry_entry_t) -> NSDictionary? {
    var properties: Unmanaged<CFMutableDictionary>? = nil

    if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) != kIOReturnSuccess {
        return nil
    }

    return properties?.takeRetainedValue()
}

// Returns a retained driver only when all ancestor branches resolve to one driver.
/// 从一块 IOMedia 往上找它的 IOBlockStorageDriver。
/// stats/Modules/Disk/readers.swift:284-...
func getDeviceIOParent(_ media: io_registry_entry_t) -> io_registry_entry_t? {
    IOObjectRetain(media)

    var entries = [media]
    defer { entries.forEach { IOObjectRelease($0) } }
    var visited: Set<UInt64> = []
    var driver: io_registry_entry_t?
    var index = 0

    while index < entries.count {
        let entry = entries[index]
        index += 1
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { return nil }
        guard visited.insert(id).inserted else { continue }
        guard visited.count <= 256 else { return nil }

        if IOObjectConformsTo(entry, kIOBlockStorageDriverClass) != 0 {
            guard driver == nil else { return nil }
            driver = entry
            continue
        }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var parent = IOIteratorNext(iterator)
        while parent != 0 {
            entries.append(parent)
            parent = IOIteratorNext(iterator)
        }
        guard IOIteratorIsValid(iterator) != 0 else { return nil }
    }

    guard let driver else { return nil }
    IOObjectRetain(driver)
    return driver
}

/// 单调时钟。差分一律用它，不用墙钟（见 docs/design.md 的「差分与速率」）。
func monotonicNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}
