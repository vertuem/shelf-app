import ShelfCore
import SwiftUI

/// Whether Shelf may read the clipboard by itself. Since macOS 15.4 an app that
/// reads the clipboard without a paste from the user triggers a privacy alert,
/// and the user chooses per app under Privacy & Security, Paste from Other Apps.
public enum ClipboardAccess: Sendable, Equatable {
    /// Always allowed, or a macOS without the setting.
    case allowed
    /// macOS has not asked yet; it will at the first copy.
    case notAskedYet
    /// macOS asks every time Shelf reads the clipboard.
    case asks
    /// Denied: Shelf records nothing.
    case denied
}

/// Whether Shelf opens at login.
public enum LoginItemState: Sendable, Equatable {
    case on
    /// First setup: Shelf adds itself when the welcome tour is done.
    case afterSetup
    /// Turned off in Settings, or not added.
    case off
}

/// One permission or setup task, with why it is needed and where it stands.
struct PermissionRow: View {
    enum Status {
        /// Granted or switched on: a green check with a word ("Allowed", "On").
        case done(String)
        /// Still to do, with the button that does it.
        case todo(String, () -> Void)
        /// Nothing to do now, with a word on when it happens.
        case info(String)

        var isDone: Bool { if case .done = self { true } else { false } }
        var isTodo: Bool { if case .todo = self { true } else { false } }
    }

    let symbol: String
    let color: Color
    let title: String
    let reason: String
    let status: Status

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            statusView
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .done(let word):
            Label(word, systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
                .fixedSize()
                .transition(.scale.combined(with: .opacity))
        case .todo(let action, let perform):
            Button(action, action: perform)
                .controlSize(.regular)
                .fixedSize()
        case .info(let word):
            Label(word, systemImage: "circle.dotted")
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

extension PermissionRow {
    /// Reading the clipboard: the one permission a clipboard manager cannot work without.
    static func clipboard(_ access: ClipboardAccess, ask: @escaping () -> Void, openSettings: @escaping () -> Void) -> PermissionRow {
        let status: Status = switch access {
        case .allowed: .done(String(localized: "Allowed"))
        case .notAskedYet: .todo(String(localized: "Ask Now"), ask)
        case .asks, .denied: .todo(String(localized: "Open Settings"), openSettings)
        }
        return PermissionRow(
            symbol: "doc.on.clipboard.fill", color: .orange,
            title: String(localized: "Read what you copy"),
            reason: String(localized: "\(Brand.name) keeps your history by reading the clipboard each time you copy. macOS asks first: choose Allow, or turn \(Brand.name) on under Privacy & Security, Paste from Other Apps. Nothing leaves your Mac."),
            status: status
        )
    }

    /// Accessibility: optional, for pasting straight into the app you were using.
    static func accessibility(granted: Bool, openSettings: @escaping () -> Void) -> PermissionRow {
        PermissionRow(
            symbol: "keyboard", color: .blue,
            title: String(localized: "Paste into your apps"),
            reason: String(localized: "Accessibility lets \(Brand.name) press ⌘V for you in the app you were using. It does not read your screen or record your keystrokes; the only key it watches is ⌘V, and only while the Paste Stack is open. Without it, \(Brand.name) copies the card and you press ⌘V."),
            status: granted ? .done(String(localized: "Allowed")) : .todo(String(localized: "Open Settings"), openSettings)
        )
    }

    /// Protected folders: macOS asks on first use, so there is nothing to do up front.
    static var files: PermissionRow {
        PermissionRow(
            symbol: "folder.fill", color: .cyan,
            title: String(localized: "Files you copy"),
            reason: String(localized: "When you copy a file from Desktop, Documents or Downloads, macOS may ask once whether \(Brand.name) can read that folder. It only reads the files you copy, to show a preview and paste them back."),
            // macOS cannot report this without asking, so there is no check to show.
            status: .info(String(localized: "Asked when needed"))
        )
    }

    /// The login item: macOS shows a notice when it is added.
    static func login(_ state: LoginItemState, turnOn: @escaping () -> Void) -> PermissionRow {
        let status: Status = switch state {
        case .on: .done(String(localized: "On"))
        case .afterSetup: .info(String(localized: "Turns on when you finish"))
        case .off: .todo(String(localized: "Turn On"), turnOn)
        }
        return PermissionRow(
            symbol: "power", color: .gray,
            title: String(localized: "Open at login"),
            reason: String(localized: "\(Brand.name) has no Dock or menu bar icon, so it adds itself to Login Items to be ready after a restart. macOS shows a notice when it does. Turn it off in Settings, General."),
            status: status
        )
    }
}

/// "2 of 3 done" above a permission checklist.
struct PermissionProgress: View {
    let rows: [PermissionRow.Status]

    var body: some View {
        let tasks = rows.filter { !isInfo($0) }
        let done = tasks.filter(\.isDone).count
        HStack(spacing: 8) {
            Image(systemName: done == tasks.count ? "checkmark.seal.fill" : "checklist")
                .foregroundStyle(done == tasks.count ? .green : .secondary)
            Text(String(localized: "\(done) of \(tasks.count) done"))
                .font(.callout.weight(.semibold))
                .contentTransition(.numericText())
            ProgressView(value: Double(done), total: Double(max(tasks.count, 1)))
                .tint(.green)
                .frame(width: 90)
            Spacer()
        }
        .animation(.smooth, value: done)
        .accessibilityElement(children: .combine)
    }

    private func isInfo(_ status: PermissionRow.Status) -> Bool {
        if case .info = status { true } else { false }
    }
}
