import Foundation
import Security

/// RFC 9562 version 7 UUIDs: 48-bit Unix milliseconds, then random bits.
///
/// Ids sort by creation time, which keeps SQLite inserts append-only and makes
/// the primary key a usable tiebreaker for items copied in the same millisecond.
public enum UUIDv7 {
    public static func make(at date: Date = Date()) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        let millis = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: millis >> (8 * (5 - index)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70 // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The timestamp embedded in a v7 UUID, or nil for other versions.
    public static func date(of uuid: UUID) -> Date? {
        let bytes = uuid.uuid
        guard bytes.6 >> 4 == 7 else { return nil }
        let parts = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5]
        let millis = parts.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}
