import AppKit
import ShelfCapture
import ShelfCore

/// A realistic mix of items for renders, demos and the onboarding recording.
@MainActor
enum SampleData {
    static func populate(_ store: Store) async {
        let now = Date()
        func snapshot(_ pairs: [(String, Data)]) -> PasteboardSnapshot {
            PasteboardSnapshot(items: [pairs.map { ClipRepresentation(uti: $0.0, data: $0.1) }])
        }
        func text(_ string: String) -> (String, Data) { (PasteboardTypes.plainText, Data(string.utf8)) }

        // A short, neutral folder: the file card's footer shows it in screenshots.
        let folder = URL(fileURLWithPath: "/tmp/Invoices", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("Invoice October.pdf")
        try? Data("%PDF-1.4".utf8).write(to: pdf)

        let samples: [(PasteboardSnapshot, String, String, TimeInterval)] = [
            (snapshot([text("Room change for Thursday\nMeeting moved to Thursday 14:00. I booked the big room and sent the new invite to everyone on the thread.")]),
             "com.apple.mail", "Mail", 40),
            (snapshot([(PasteboardTypes.url, Data("https://developer.apple.com/documentation/appkit/nspasteboard".utf8)),
                       text("https://developer.apple.com/documentation/appkit/nspasteboard")]),
             "com.apple.Safari", "Safari", 180),
            (snapshot([(PasteboardTypes.png, sampleImage())]), "com.apple.Preview", "Preview", 420),
            (snapshot([text("#1E90FF")]), "com.figma.Desktop", "Figma", 900),
            (snapshot([(PasteboardTypes.rtf, Data("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs26 {\\b Quarterly report:} revenue up {\\i 12 percent}, churn down to 2.1 percent. Full numbers in the appendix.}".utf8)),
                       text("Quarterly report: revenue up 12 percent, churn down to 2.1 percent. Full numbers in the appendix.")]),
             "com.apple.iWork.Pages", "Pages", 3_600),
            (snapshot([(PasteboardTypes.fileURL, Data(pdf.absoluteString.utf8)), text(pdf.lastPathComponent)]),
             "com.apple.finder", "Finder", 7_200),
            (snapshot([text("enum DayOfWeek: CaseIterable {\n    case monday, tuesday\n    // Weekend days paste as plain text\n    var isWeekend: Bool { self == .saturday }\n}")]),
             "com.apple.dt.Xcode", "Xcode", 50_000),
            (snapshot([text("git rebase -i origin/main && swift test --parallel")]),
             "com.apple.Terminal", "Terminal", 86_000),
            (snapshot([text("Shelf · the Paste shelf for macOS, native, open source, no subscription")]),
             "com.apple.Notes", "Notes", 200_000),
        ]
        var stored: [ClipItem] = []
        for (snapshot, bundleID, name, age) in samples.reversed() {
            let captured = ItemBuilder.build(from: snapshot, source: SourceApp(bundleID: bundleID, name: name),
                                             maxItemBytes: 10_000_000, now: now.addingTimeInterval(-age))
            if let item = try? await store.insert(captured) { stored.append(item) }
        }
        if let snippets = try? await store.createPinboard(name: "Snippets", color: .orange, icon: "star"),
           let first = stored.first {
            try? await store.pin(first.id, to: snippets.id)
        }
        _ = try? await store.createPinboard(name: "Design", color: .purple)
        _ = try? await store.createPinboard(name: "Work", color: .green)
    }

    /// A small landscape picture drawn in code, so no image asset ships for samples.
    static func sampleImage() -> Data {
        let size = NSSize(width: 960, height: 640)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [.systemOrange, .systemPink, .systemPurple])?.draw(in: rect, angle: 70)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 640, y: 380, width: 160, height: 160)).fill()
            NSColor.black.withAlphaComponent(0.35).setFill()
            let hills = NSBezierPath()
            hills.move(to: .zero)
            hills.curve(to: NSPoint(x: 960, y: 120), controlPoint1: NSPoint(x: 300, y: 380), controlPoint2: NSPoint(x: 600, y: 0))
            hills.line(to: NSPoint(x: 960, y: 0))
            hills.close()
            hills.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
}
