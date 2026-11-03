import Foundation

/// 照搬自 stats/Modules/Disk/readers.swift:268-279。
/// 单调计数器求差：now < prev（回绕）或 elapsed 非正时，速率记 0 而不是负数。
func counterActivity(_ value: Any?, previous: UInt64?, elapsed: Double) -> (bytes: UInt64?, rate: Int64) {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
          ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
          let bytes = UInt64(number.stringValue) else {
        return (nil, 0)
    }
    guard let previous, bytes >= previous, elapsed > 0, elapsed.isFinite else {
        return (bytes, 0)
    }

    let rate = Double(bytes - previous) / elapsed
    return (bytes, rate >= Double(Int64.max) ? Int64.max : Int64(rate))
}
