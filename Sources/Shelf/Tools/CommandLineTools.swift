import AppKit
import ShelfCapture
import ShelfCore

/// Developer tools built into the app binary. Return false for a normal launch.
@MainActor
enum CommandLineTools {
    static func run(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        switch arguments[1] {
        case "--version":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            print("\(Brand.name) \(version)")
            return true
        case "--dump-pasteboard":
            print(dumpPasteboard(name: arguments.count > 2 ? arguments[2] : "fixture"))
            return true
        case "--render-demo":
            let file = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "demo.gif")
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in
                await PreviewRenderer.renderDemo(to: file)
                exit(0)
            }
            NSApplication.shared.run()
            return true
        case "--render-previews":
            let folder = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "previews", isDirectory: true)
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in
                await PreviewRenderer.renderAll(to: folder)
                exit(0)
            }
            NSApplication.shared.run()
            return true
        default:
            return false
        }
    }

    /// The general pasteboard in the fixture format used by `ClassifierTests`.
    /// Copy something in the app you want to cover, run this, and save the output
    /// under `Tests/ShelfTests/Fixtures/`. Large payloads are truncated to 4 KB;
    /// check the output for anything private before committing it.
    static func dumpPasteboard(name: String) -> String {
        let snapshot = PasteboardSnapshot.read(from: .general)
        let source = SourceResolver.frontmost()
        let items = snapshot.items.map { item in
            item.map { representation in
                ["type": representation.uti, "base64": representation.data.prefix(4_096).base64EncodedString()]
            }
        }
        let fixture: [String: Any] = [
            "name": name,
            "app": source.name ?? "Unknown",
            "expectedKind": Classifier.classify(snapshot).rawValue,
            "items": items,
            "promised": snapshot.promisedTypes,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
