import os

/// Loggers by area. Never interpolate clipboard content: previews, URLs and file
/// paths stay out of logs entirely, and ids are logged as `.public` only.
public enum Log {
    public static let capture = Logger(subsystem: Brand.releaseBundleID, category: "capture")
    public static let store = Logger(subsystem: Brand.releaseBundleID, category: "store")
    public static let paste = Logger(subsystem: Brand.releaseBundleID, category: "paste")
    public static let ui = Logger(subsystem: Brand.releaseBundleID, category: "ui")
    public static let update = Logger(subsystem: Brand.releaseBundleID, category: "update")
}
