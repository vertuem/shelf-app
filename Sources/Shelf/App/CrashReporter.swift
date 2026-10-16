import AppKit
import ShelfCore
import ShelfPaste

/// "Report a Crash…" in About: copies the newest crash log and opens a new
/// GitHub issue. Opt-in by design; nothing is uploaded automatically.
@MainActor
enum CrashReporter {
    static var latestReport: URL? {
        let folders = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        ]
        let reports = folders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        .filter { $0.lastPathComponent.hasPrefix(Brand.name) && ["ips", "crash"].contains($0.pathExtension) }
        return reports.max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func report(version: String) {
        guard let url = latestReport, let log = try? String(contentsOf: url, encoding: .utf8) else {
            let alert = NSAlert()
            alert.messageText = String(localized: "No crash logs found")
            alert.informativeText = String(localized: "\(Brand.name) has not crashed on this Mac, or macOS has already removed the log.")
            NSApp.activate()
            alert.runModal()
            return
        }
        PasteboardWriter.writePlainText(log, to: .general)
        var components = URLComponents(url: Brand.repositoryURL.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "template", value: "crash.yml"),
            URLQueryItem(name: "title", value: "Crash in \(version)"),
        ]
        if let issueURL = components.url {
            NSWorkspace.shared.open(issueURL)
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Crash log copied")
        alert.informativeText = String(localized: "Paste it into the issue that just opened in your browser. Crash logs contain no clipboard content.")
        NSApp.activate()
        alert.runModal()
    }
}
