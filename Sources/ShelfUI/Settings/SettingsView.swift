import AppKit
import ShelfCore
import SwiftUI

/// What the settings panes need from the app beyond `UserDefaults`.
@MainActor
public protocol SettingsBackend: AnyObject {
    var launchAtLogin: Bool { get set }
    var isAccessibilityGranted: Bool { get }
    func openAccessibilitySettings()
    var clipboardAccess: ClipboardAccess { get }
    func requestClipboardAccess()
    func openClipboardSettings()
    /// The preview button next to a sound setting.
    func playSound(_ effect: SoundEffect)

    func statistics() async -> Store.Statistics?
    func eraseHistory(keepPinned: Bool) async
    func removeOldImages() async -> Int
    func exportHistory() async
    func importHistory() async
    var maccyDatabaseFound: Bool { get }
    func importFromMaccy() async
    var pasteDatabaseFound: Bool { get }
    func importFromPaste() async

    var versionString: String { get }
    var isDevelopmentBuild: Bool { get }
    /// Not signed by Apple: updates are checked against the release's checksum, not a Developer ID.
    var updatesAreUnsigned: Bool { get }
    var updateStatus: String { get }
    var isCheckingForUpdates: Bool { get }
    func checkForUpdates()
    func rerunOnboarding()
    func reportCrash()
    func quit()
}

/// The Settings window: General, Privacy, Shortcuts, About.
///
/// A `NavigationSplitView`, so macOS 26 draws its floating Liquid Glass
/// sidebar and macOS 14 and 15 the standard one.
/// Every pane is a grouped `Form` that opens with a header naming the pane.
public struct SettingsView: View {
    public enum Pane: String, CaseIterable, Identifiable, Sendable {
        case general, privacy, shortcuts, about
        public var id: String { rawValue }

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .privacy: String(localized: "Privacy")
            case .shortcuts: String(localized: "Shortcuts")
            case .about: String(localized: "About")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .privacy: "hand.raised.fill"
            case .shortcuts: "command"
            case .about: "info"
            }
        }

        var color: Color {
            switch self {
            case .general: .gray
            case .privacy: .blue
            case .shortcuts: .indigo
            case .about: .teal
            }
        }

        var summary: String {
            switch self {
            case .general: String(localized: "How \(Brand.name) opens, pastes and keeps your history.")
            case .privacy: String(localized: "Choose what is never recorded and how your history is stored.")
            case .shortcuts: String(localized: "Open the shelf from anywhere, and every key that works inside it.")
            case .about: ""
            }
        }
    }

    let backend: any SettingsBackend
    @State private var selection: Pane

    public init(backend: any SettingsBackend, initialPane: Pane = .general) {
        self.backend = backend
        _selection = State(initialValue: initialPane)
    }

    public var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    IconTile(symbol: pane.symbol, color: pane.color)
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            content(for: selection)
                .navigationTitle(selection.title)
                .background(WindowTitle(title: selection.title))
                // The toolbar's full height plus the form's own margin left a
                // wide empty band under the pane title; this keeps a smaller one.
                .safeAreaPadding(.top, 30)
                .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private func content(for pane: Pane) -> some View {
        switch pane {
        case .general: GeneralPane(backend: backend)
        case .privacy: PrivacyPane()
        case .shortcuts: ShortcutsPane()
        case .about: AboutPane(backend: backend)
        }
    }
}

/// Sets the hosting window's title. `navigationTitle` only reaches windows
/// that SwiftUI scenes own; Settings is an `NSWindow` (entry 28).
private struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let title = self.title
        DispatchQueue.main.async { view.window?.title = title }
    }
}

/// The first section of a pane: its icon, name and what it is for, as in System Settings.
struct PaneHeader: View {
    let pane: SettingsView.Pane

    var body: some View {
        Section {
            HStack(spacing: 14) {
                IconTile(symbol: pane.symbol, color: pane.color, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pane.title)
                        .font(.title2.weight(.semibold))
                    Text(pane.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A section with a header that sits closer to its group. The grouped form's
/// own header spacing on macOS 26 left the panes looking sparse.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            SectionHeader(title)
        }
    }
}

/// A form section header with less space above and below it on macOS 26.
struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        if #available(macOS 26, *), !ShelfAppearance.forceLegacy {
            Text(title)
                .padding(.top, -14)
                .padding(.bottom, -6)
        } else {
            Text(title)
        }
    }
}

/// A switch with an optional explanation under its title.
struct SettingToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            if let detail {
                Text(detail)
            }
        }
    }
}

/// A grouped form, the stock macOS settings look.
struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let form = Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        if #available(macOS 26, *) {
            // Content fades under the toolbar instead of meeting a hard line.
            form.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            form
        }
    }
}

/// A short explanation under a row.
struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A Settings window hosting `SettingsView`.
///
/// An `NSWindow` rather than a SwiftUI `Settings` scene, because a menu-bar app
/// must open it from places outside any SwiftUI scene: the shelf's gear button,
/// the URL scheme, onboarding, and relaunching from Spotlight.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let backend: any SettingsBackend

    public init(backend: any SettingsBackend) {
        self.backend = backend
    }

    /// `activate: false` orders the window in without taking focus, for review captures.
    public func show(pane: SettingsView.Pane? = nil, activate: Bool = true) {
        if let pane {
            window?.close()
            window = nil
            makeWindow(pane: pane)
        } else if window == nil {
            makeWindow(pane: .general)
        }
        guard activate else {
            window?.orderFrontRegardless()
            return
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(pane: SettingsView.Pane) {
        let controller = NSHostingController(rootView: SettingsView(backend: backend, initialPane: pane))
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.title = pane.title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // A toolbar is what lets macOS 26 float the sidebar as Liquid Glass.
        window.toolbar = NSToolbar(identifier: "Settings")
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 560))
        window.setFrameAutosaveName("Settings")
        window.delegate = self
        if !window.setFrameUsingName("Settings") { window.center() }
        self.window = window
    }

    public nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // An agent app returns focus to whatever was frontmost before.
            NSApp.hide(nil)
        }
    }
}
