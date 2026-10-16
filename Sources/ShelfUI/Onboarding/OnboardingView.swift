import KeyboardShortcuts
import ShelfCore
import SwiftUI

/// What onboarding needs from the app.
@MainActor
public protocol OnboardingBackend: AnyObject {
    var isAccessibilityGranted: Bool { get }
    func requestAccessibility()
    var clipboardAccess: ClipboardAccess { get }
    /// Reads the clipboard once, so macOS asks now rather than at the first copy.
    func requestClipboardAccess()
    func openClipboardSettings()
    var loginItemState: LoginItemState { get }
    func turnOnLoginItem()
    /// Names of other clipboard managers that are running right now.
    var runningClipboardManagers: [String] { get }
    func createSnippetsPinboard() async
    /// Called once, from the last screen or the close button.
    func finishOnboarding(accessibilitySkipped: Bool)
}

/// The onboarding steps, separate from the view so the flow is unit-tested.
@MainActor
@Observable
public final class OnboardingFlow {
    public enum Step: Int, CaseIterable { case welcome, permissions, hotkey }

    public private(set) var step: Step = .welcome
    public var accessibilityGranted = false
    public var clipboardAccess = ClipboardAccess.notAskedYet
    public var loginItemState = LoginItemState.afterSetup
    public private(set) var skippedAccessibility = false
    public var createSnippets = true
    public private(set) var isFinished = false
    private let backend: any OnboardingBackend

    public init(backend: any OnboardingBackend, step: Step = .welcome) {
        self.backend = backend
        self.step = step
        accessibilityGranted = backend.isAccessibilityGranted
        clipboardAccess = backend.clipboardAccess
        loginItemState = backend.loginItemState
    }

    public var canGoBack: Bool { step != .welcome }
    /// Both permissions granted: nothing left to do.
    public var permissionsDone: Bool { accessibilityGranted && clipboardAccess == .allowed }
    /// Skip is offered on the permissions step until both are granted.
    public var canSkip: Bool { step == .permissions && !permissionsDone }

    public func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        step = following
    }

    public func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    public func skipAccessibility() {
        skippedAccessibility = true
        step = .hotkey
    }

    public func refreshAccessibility() {
        accessibilityGranted = backend.isAccessibilityGranted
        clipboardAccess = backend.clipboardAccess
        loginItemState = backend.loginItemState
    }

    public func turnOnLoginItem() {
        backend.turnOnLoginItem()
        refreshAccessibility()
    }

    public func requestAccessibility() {
        backend.requestAccessibility()
    }

    public func requestClipboardAccess() {
        backend.requestClipboardAccess()
        refreshAccessibility()
    }

    public func openClipboardSettings() {
        backend.openClipboardSettings()
    }

    /// Done: creates the Snippets board if asked, then hands control back to the app.
    public func finish() async {
        guard !isFinished else { return }
        isFinished = true
        if createSnippets { await backend.createSnippetsPinboard() }
        backend.finishOnboarding(accessibilitySkipped: skippedAccessibility && !accessibilityGranted)
    }
}

/// First launch only, three screens: what Shelf does, Accessibility, and the
/// hotkey with a one-click Snippets pinboard. Can be re-run from About.
public struct OnboardingView: View {
    let backend: any OnboardingBackend
    @State private var flow: OnboardingFlow
    @AppStorage(PrefKey.showInMenuBar) private var showInMenuBar = false

    /// `step` opens a later page, for reviewing the design.
    public init(backend: any OnboardingBackend, step: OnboardingFlow.Step = .welcome) {
        self.backend = backend
        _flow = State(initialValue: OnboardingFlow(backend: backend, step: step))
    }

    private var accessibilityGranted: Bool { flow.accessibilityGranted }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                switch flow.step {
                case .welcome: welcome
                case .permissions: permissions
                case .hotkey: hotkey
                }
            }
            .id(flow.step)
            .transition(.blurReplace)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 36)
            footer
        }
        .frame(width: 660, height: 700)
        .background(OnboardingBackdrop())
        .task {
            while !Task.isCancelled {
                flow.refreshAccessibility()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func go(_ change: () -> Void) {
        withAnimation(.smooth(duration: 0.35)) { change() }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 22) {
            OnboardingDemo()
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            VStack(spacing: 8) {
                Text(String(localized: "Everything you copy, one keystroke away"))
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(String(localized: "\(Brand.name) keeps what you copy on a shelf at the bottom of the screen. Press the shortcut, arrow to a card, press Return, and it is pasted where you were typing."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 16) {
                FeatureColumn(symbol: "pin.fill", color: .orange,
                              title: String(localized: "Pinboards"),
                              detail: String(localized: "Keep the things you paste every day, sorted by color."))
                FeatureColumn(symbol: "magnifyingglass", color: .blue,
                              title: String(localized: "Instant search"),
                              detail: String(localized: "Find anything by its text, app, type or date."))
                FeatureColumn(symbol: "lock.fill", color: .green,
                              title: String(localized: "Private by design"),
                              detail: String(localized: "Stays on your Mac, encrypted, and skips passwords."))
            }
        }
    }

    private var permissions: some View {
        VStack(spacing: 16) {
            PageHero(symbol: flow.permissionsDone ? "checkmark.shield.fill" : "hand.raised.fill",
                     color: flow.permissionsDone ? .green : .blue,
                     title: String(localized: "What \(Brand.name) needs, and why"))
            let rows = [
                PermissionRow.clipboard(flow.clipboardAccess, ask: { flow.requestClipboardAccess() },
                                        openSettings: { flow.openClipboardSettings() }),
                PermissionRow.accessibility(granted: accessibilityGranted) { flow.requestAccessibility() },
                PermissionRow.files,
                PermissionRow.login(flow.loginItemState) { flow.turnOnLoginItem() },
            ]
            VStack(spacing: 10) {
                PermissionProgress(rows: rows.map(\.status))
                ForEach(rows.indices, id: \.self) { index in
                    Divider().padding(.leading, index == 0 ? 0 : 42)
                    rows[index]
                }
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .animation(.smooth, value: flow.permissionsDone)
            let managers = backend.runningClipboardManagers
            if !managers.isEmpty {
                Label(String(localized: "\(managers.joined(separator: ", ")) is also running. Two clipboard managers record every copy twice; consider turning one off."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// On the last page: what is still to do, or that everything is set.
    @ViewBuilder
    private var setupSummary: some View {
        let missing = [
            flow.clipboardAccess == .allowed ? nil : String(localized: "allow reading what you copy"),
            accessibilityGranted ? nil : String(localized: "allow Accessibility to paste"),
        ].compactMap { $0 }
        if missing.isEmpty {
            Label(String(localized: "All permissions are set."), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))
        } else {
            Label(String(localized: "Still to do: \(missing.formatted(.list(type: .and))). Go Back, or later in Settings, General."),
                  systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hotkey: some View {
        VStack(spacing: 14) {
            PageHero(symbol: "command", color: .indigo, title: String(localized: "Your shortcut"))
            Text(String(localized: "\(Brand.name) runs in the background, with no Dock or menu bar icon, and opens at login. Press the shortcut anywhere to open the shelf; press it again, or Escape, to close it."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Form {
                Section {
                    KeyboardShortcuts.Recorder(String(localized: "Open the shelf:"), name: .activateShelf)
                    KeyboardShortcuts.Recorder(String(localized: "Open the Paste Stack:"), name: .activatePasteStack)
                }
                Section {
                    Toggle(isOn: $flow.createSnippets) {
                        Text(String(localized: "Create a Snippets pinboard"))
                        Text(String(localized: "A place for the things you paste every day. Pinned items never expire."))
                    }
                    Toggle(isOn: $showInMenuBar) {
                        Text(String(localized: "Show an icon in the menu bar"))
                        Text(String(localized: "Off by default. Without it, open \(Brand.name) from Spotlight to reach Settings."))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: 270)
            .padding(.horizontal, -20)
            setupSummary
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            PageIndicator(current: flow.step.rawValue, count: OnboardingFlow.Step.allCases.count)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Step \(flow.step.rawValue + 1) of 3"))
            Spacer()
            if flow.canGoBack {
                Button(String(localized: "Back")) { go { flow.back() } }
                    .shelfSecondaryButtonStyle()
            }
            if flow.canSkip {
                Button(String(localized: "Skip")) { go { flow.skipAccessibility() } }
                    .shelfSecondaryButtonStyle()
            }
            if flow.step == .hotkey {
                Button(String(localized: "Done")) { Task { await flow.finish() } }
                    .shelfProminentButtonStyle()
                    .keyboardShortcut(.defaultAction)
            } else if !flow.canSkip {
                Button(String(localized: "Continue")) { go { flow.next() } }
                    .shelfProminentButtonStyle()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }
}

/// A big icon tile and the page title.
private struct PageHero: View {
    let symbol: String
    let color: Color
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 72, height: 72)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: color.opacity(0.35), radius: 12, y: 6)
                .animation(.smooth, value: symbol)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
        }
    }
}

/// One of the three features under the welcome demo.
private struct FeatureColumn: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            IconTile(symbol: symbol, color: color, size: 32)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Dots, with the current page drawn as a wider capsule.
private struct PageIndicator: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .animation(.smooth, value: current)
    }
}

/// A soft wash of color behind the window content, so the page is not flat white.
private struct OnboardingBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.indigo.opacity(colorScheme == .dark ? 0.28 : 0.14), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color.teal.opacity(colorScheme == .dark ? 0.22 : 0.12), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 480)
        }
        .ignoresSafeArea()
    }
}

/// The looping demo on the first screen: six seconds of cards sliding onto a shelf.
struct OnboardingDemo: View {
    var body: some View {
        AnimatedShelfDemo()
    }
}

/// A drawn demo: a desktop, then the shelf
/// sliding up with cards, the selection moving, and the shelf closing.
struct AnimatedShelfDemo: View {
    private let samples: [(ContentKind, String)] = [
        (.text, "Meeting notes: ship Friday"),
        (.link, "github.com"),
        (.image, ""),
        (.color, "#1E90FF"),
        (.richText, "Quarterly report"),
        (.file, "Invoice.pdf"),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6)
            let shown = time < 0.4 ? time / 0.4 : time > 5.4 ? max(0, (5.8 - time) / 0.4) : 1
            let selected = min(3, max(0, Int((time - 1) / 0.9)))
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    DemoWallpaper()
                    HStack(spacing: 10) {
                        ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                            miniCard(kind: sample.0, text: sample.1, selected: index == selected)
                        }
                    }
                    .padding(12)
                    .frame(width: geometry.size.width - 20)
                    .shelfMaterial(cornerRadius: 22)
                    .padding(10)
                    .offset(y: (1 - shown) * 140)
                    .opacity(shown)
                }
            }
        }
        .accessibilityLabel(String(localized: "Animation of the shelf opening with cards"))
    }

    private func miniCard(kind: ContentKind, text: String, selected: Bool) -> some View {
        let header = kind == .color ? (Color(hex: text) ?? .blue) : kind.headerColor
        return VStack(spacing: 0) {
            Text(kind.displayName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(kind == .richText || kind == .file ? .black : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(header.gradient)
            Group {
                if kind == .image {
                    Image(systemName: "photo.fill").font(.system(size: 22)).foregroundStyle(.red.opacity(0.6))
                } else {
                    Text(text).font(.system(size: 8)).lineLimit(3).foregroundStyle(.black)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(4)
        }
        .frame(width: 68, height: 80)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .scaleEffect(selected ? 1.06 : 1)
        .animation(.easeOut(duration: 0.1), value: selected)
    }
}

/// A desktop picture for the demo: a mesh of color on macOS 15 and later.
private struct DemoWallpaper: View {
    var body: some View {
        if #available(macOS 15, *) {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.6, 0.4], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                .indigo, .purple, .pink,
                .blue, .indigo, .orange,
                .teal, .blue, .purple,
            ])
        } else {
            LinearGradient(colors: [.indigo, .purple, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// The onboarding window.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let backend: any OnboardingBackend

    public init(backend: any OnboardingBackend) {
        self.backend = backend
    }

    /// `activate: false` orders the window in without taking focus, for review captures.
    public func show(step: OnboardingFlow.Step = .welcome, activate: Bool = true) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(backend: backend, step: step)))
            window.title = String(localized: "Welcome to \(Brand.name)")
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        guard activate else {
            window?.orderFrontRegardless()
            return
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.delegate = nil
        window?.close()
        window = nil
        NSApp.hide(nil)
    }

    public nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Closing the window counts as finishing; it can be re-run from About.
            window = nil
            backend.finishOnboarding(accessibilitySkipped: !backend.isAccessibilityGranted)
        }
    }
}
