import AppKit
import ShelfCore
import ShelfUI
import SwiftUI

/// The app: a menu-bar item and nothing in the Dock (`LSUIElement`). Every
/// window is opened on demand by `AppServices`.
struct ShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(PrefKey.showInMenuBar) private var showInMenuBar = false

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarContent(backend: delegate.services)
        } label: {
            MenuBarIcon(services: delegate.services)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "Settings…")) { delegate.services.openSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {
                Button(String(localized: "\(Brand.name) Keyboard Shortcuts")) { delegate.services.showCheatSheet() }
                    .keyboardShortcut("/")
                Button(String(localized: "\(Brand.name) on GitHub")) { NSWorkspace.shared.open(Brand.repositoryURL) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = AppServices()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.removePreviewFiles()
    }

    /// Opening Shelf again (Spotlight, Finder) while it runs shows Settings:
    /// the way back when the menu-bar item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services.openSettings()
        return false
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string) else { return }
        services.handle(url)
    }
}

/// The clipboard icon; gray while capture is paused.
struct MenuBarIcon: View {
    let services: AppServices

    var body: some View {
        let paused = (services.pausedUntil ?? .distantPast) > Date()
        Image(nsImage: Self.image(paused: paused))
            .accessibilityLabel(paused ? String(localized: "\(Brand.name), capture paused") : Brand.name)
    }

    static func image(paused: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbol = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: Brand.name)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        guard paused else {
            symbol.isTemplate = true
            return symbol
        }
        // Template images are drawn from their alpha; a faint glyph reads as gray.
        let faded = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35)
            return true
        }
        faded.isTemplate = true
        return faded
    }
}
