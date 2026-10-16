import Foundation

/// The "Keep history" slider in General settings.
public enum RetentionPeriod: String, Sendable, CaseIterable {
    case day, week, month, year, forever

    /// Items whose last use is older than this are purged. Nil keeps everything.
    public var interval: TimeInterval? {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .year: 365 * 86_400
        case .forever: nil
        }
    }

    public var displayName: String {
        switch self {
        case .day: String(localized: "Day")
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        case .year: String(localized: "Year")
        case .forever: String(localized: "Forever")
        }
    }

    /// The cutoff before which unpinned items are deleted.
    public func cutoff(now: Date = Date()) -> Date? {
        interval.map { now.addingTimeInterval(-$0) }
    }

    /// The hard cap that applies whatever the setting, oldest first.
    public static let hardCapUnpinnedItems = 50_000
}
