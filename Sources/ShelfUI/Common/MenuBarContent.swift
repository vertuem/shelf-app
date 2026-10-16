import ShelfCore
import SwiftUI

/// What the menu-bar window needs from the app.
@MainActor
public protocol MenuBarBackend: AnyObject {
    var pausedUntil: Date? { get }
    func openShelf()
    func togglePasteStack()
    func pause(minutes: Int?)
    func resume()
    func openSettings()
    func showCheatSheet()
    func quit()
}

/// The contents of the `MenuBarExtra` window: Open Shelf, Open Paste Stack,
/// pause capture for 15 minutes, an hour or until resumed, Settings, Quit.
public struct MenuBarContent: View {
    let backend: any MenuBarBackend
    @AppStorage(PrefKey.alwaysPastePlainText) private var alwaysPlain = false
    @Environment(\.dismiss) private var dismiss

    public init(backend: any MenuBarBackend) {
        self.backend = backend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(String(localized: "Open \(Brand.name)"), symbol: "rectangle.bottomthird.inset.filled",
                shortcut: Hotkeys.display(.activateShelf)) { backend.openShelf() }
            row(String(localized: "Open Paste Stack"), symbol: "square.stack.3d.down.right",
                shortcut: Hotkeys.display(.activatePasteStack)) { backend.togglePasteStack() }
            Divider().padding(.vertical, 4)
            if let until = backend.pausedUntil, until > Date() {
                Text(until == .distantFuture
                    ? String(localized: "Capture paused")
                    : String(localized: "Capture paused until \(until.formatted(date: .omitted, time: .shortened))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                row(String(localized: "Resume Capture"), symbol: "play.fill", shortcut: Hotkeys.displayIfSet(.togglePause)) { backend.resume() }
            } else {
                row(String(localized: "Pause for 15 Minutes"), symbol: "pause") { backend.pause(minutes: 15) }
                row(String(localized: "Pause for 1 Hour"), symbol: "pause") { backend.pause(minutes: 60) }
                row(String(localized: "Pause Until Resumed"), symbol: "pause.fill", shortcut: Hotkeys.displayIfSet(.togglePause)) { backend.pause(minutes: nil) }
            }
            Divider().padding(.vertical, 4)
            Toggle(String(localized: "Paste as Plain Text"), isOn: $alwaysPlain)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            Divider().padding(.vertical, 4)
            row(String(localized: "Keyboard Shortcuts"), symbol: "keyboard") { backend.showCheatSheet() }
            row(String(localized: "Settings…"), symbol: "gearshape", shortcut: "⌘,") { backend.openSettings() }
            row(String(localized: "Quit \(Brand.name)"), symbol: "power", shortcut: "⌘Q") { backend.quit() }
        }
        .padding(6)
        .frame(width: 260)
    }

    private func row(_ title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        MenuRow(title: title, symbol: symbol, shortcut: shortcut) {
            dismiss()
            action()
        }
    }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(hovering ? .white : .primary)
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
