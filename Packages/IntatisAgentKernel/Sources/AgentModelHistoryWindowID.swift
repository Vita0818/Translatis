import Foundation

/// UUIDv7 generator for durable model-history windows. The timestamp provides
/// sortable identity while EventLog `seq` remains the authoritative order.
enum AgentModelHistoryWindowID {
    static func new(now: Date = Date()) -> String {
        let milliseconds = max(
            0,
            UInt64(now.timeIntervalSince1970 * 1_000))
        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<16).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        bytes[0] = UInt8(truncatingIfNeeded: milliseconds >> 40)
        bytes[1] = UInt8(truncatingIfNeeded: milliseconds >> 32)
        bytes[2] = UInt8(truncatingIfNeeded: milliseconds >> 24)
        bytes[3] = UInt8(truncatingIfNeeded: milliseconds >> 16)
        bytes[4] = UInt8(truncatingIfNeeded: milliseconds >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: milliseconds)
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBufferPointer {
            NSUUID(uuidBytes: $0.baseAddress!).uuidString.lowercased()
        }
    }
}
