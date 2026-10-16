import AppKit
import Carbon.HIToolbox
import ShelfCore
import SwiftUI

/// What the Paste Stack panel needs to show. `PasteStack` in ShelfPaste
/// conforms in the app target, which keeps ShelfUI free of event taps.
@MainActor
public protocol PasteStackPresenting: AnyObject {
    var ordered: [ClipItem] { get }
    var pasted: Set<UUID> { get }
    var next: ClipItem? { get }
    var reversed: Bool { get set }
    var isTapActive: Bool { get }
    var remainingCount: Int { get }
    var isNextReady: Bool { get }
    func close()
    func clear()
    func remove(_ item: ClipItem)
    func copyByClick(_ item: ClipItem) async
}

/// The row the keyboard points at in the Paste Stack panel.
@MainActor
@Observable
public final class PasteStackSelection {
    public var highlightedID: UUID?
    public init() {}
}

/// A small floating panel on the right edge listing the queue. ↑ and ↓ move
/// between rows, Return copies the highlighted row (as a click does), Delete
/// takes it out of the queue, Escape closes the panel.
@MainActor
public final class PasteStackPanelController {
    private let panel: NSPanel
    private let stack: any PasteStackPresenting
    private let selection = PasteStackSelection()
    private var keyMonitor: Any?
    public var onClose: () -> Void = {}

    public init(stack: any PasteStackPresenting, preferences: Preferences, thumbnails: ThumbnailCache) {
        panel = ShelfPanel()
        panel.setContentSize(NSSize(width: 300, height: 460))
        self.stack = stack
        // Assigned after init; the close button must go through the app so the panel hides too.
        var closeAction: () -> Void = {}
        let view = PasteStackView(stack: stack, selection: selection, thumbnails: thumbnails) { closeAction() }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.level = .floating
        panel.setAccessibilityLabel(String(localized: "Paste Stack"))
        self.preferences = preferences
        closeAction = { [weak self] in self?.onClose() }
    }

    private let preferences: Preferences

    public var isVisible: Bool { panel.isVisible }

    public func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = NSSize(width: 300, height: min(460, visible.height - 40))
            panel.setFrame(NSRect(x: visible.maxX - size.width - 16, y: visible.midY - size.height / 2,
                                  width: size.width, height: size.height), display: false)
        }
        panel.sharingType = preferences.showDuringScreenSharing ? .readOnly : .none
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        selection.highlightedID = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Returns true when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.isEmpty else { return false }
        let ordered = stack.ordered
        switch Int(event.keyCode) {
        case kVK_Escape:
            onClose()
        case kVK_UpArrow, kVK_DownArrow:
            guard !ordered.isEmpty else { return true }
            let step = Int(event.keyCode) == kVK_UpArrow ? -1 : 1
            let current = ordered.firstIndex { $0.id == selection.highlightedID }
            let next = current.map { min(max($0 + step, 0), ordered.count - 1) } ?? (step > 0 ? 0 : ordered.count - 1)
            selection.highlightedID = ordered[next].id
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard let item = ordered.first(where: { $0.id == selection.highlightedID }) else { return false }
            Task { await stack.copyByClick(item) }
        case kVK_Delete, kVK_ForwardDelete:
            guard let index = ordered.firstIndex(where: { $0.id == selection.highlightedID }) else { return false }
            stack.remove(ordered[index])
            let remaining = stack.ordered
            selection.highlightedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        default:
            return false
        }
        return true
    }

    public func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}

/// The panel's content, for offscreen renders.
public struct PasteStackPanelPreview: View {
    let stack: any PasteStackPresenting
    let thumbnails: ThumbnailCache

    public init(stack: any PasteStackPresenting, thumbnails: ThumbnailCache) {
        self.stack = stack
        self.thumbnails = thumbnails
    }

    public var body: some View {
        PasteStackView(stack: stack, selection: PasteStackSelection(), thumbnails: thumbnails) {}
    }
}

struct PasteStackView: View {
    let stack: any PasteStackPresenting
    let selection: PasteStackSelection
    let thumbnails: ThumbnailCache
    let close: () -> Void
    @AppStorage(PrefKey.cardColors) private var cardColors = CardColorMode.app.rawValue
    private var colorsFromApp: Bool { cardColors == CardColorMode.app.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if stack.ordered.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 30, weight: .light))
                    Text(String(localized: "Copy things in the order you want to paste them."))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(stack.ordered.enumerated()), id: \.element.id) { index, item in
                            row(item, number: index + 1)
                        }
                    }
                }
            }
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 24 = the rows' 10 point corners plus the 14 point inset: concentric.
        .shelfMaterial(cornerRadius: 24)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(localized: "Paste Stack"))
                .font(.headline)
            if !stack.ordered.isEmpty {
                // Progress through the queue, so a long form is easy to follow.
                Text(String(localized: "\(stack.pasted.count) of \(stack.ordered.count)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel(String(localized: "\(stack.pasted.count) of \(stack.ordered.count) pasted"))
            }
            Spacer()
            ShelfGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        stack.reversed.toggle()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(stack.reversed ? Color.accentColor : .primary)
                            .frame(width: 16, height: 16)
                    }
                    .shelfIconButtonStyle()
                    .help(String(localized: "Paste newest first"))
                    .accessibilityLabel(String(localized: "Reverse order"))
                    .accessibilityAddTraits(stack.reversed ? .isSelected : [])
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .frame(width: 16, height: 16)
                    }
                    .shelfIconButtonStyle()
                    .help(String(localized: "Close Paste Stack (Esc)"))
                    .accessibilityLabel(String(localized: "Close"))
                }
            }
        }
    }

    private func row(_ item: ClipItem, number: Int) -> some View {
        let isNext = stack.next?.id == item.id
        let isDone = stack.pasted.contains(item.id)
        let isHighlighted = selection.highlightedID == item.id
        return Button {
            Task { await stack.copyByClick(item) }
        } label: {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .frame(width: 20, height: 20)
                    .background(item.palette(fromApp: colorsFromApp).header, in: Circle())
                    .foregroundStyle(item.palette(fromApp: colorsFromApp).darkText ? .black : .white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.preview.isEmpty ? item.kind.displayName : item.preview)
                        .lineLimit(2)
                        .font(.system(size: 12))
                    Text(item.sourceAppName ?? item.kind.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isNext {
                    Text(String(localized: "Next"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(8)
            .background(isNext ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isHighlighted ? 1 : 0))
            .opacity(isDone ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selection.highlightedID = item.id } }
        .contextMenu {
            Button(String(localized: "Remove from Stack"), systemImage: "minus.circle") { stack.remove(item) }
        }
        .accessibilityLabel(Formatters.accessibilityLabel(for: item))
        .accessibilityValue(isNext ? String(localized: "Next") : isDone ? String(localized: "Pasted") : "")
    }

    private var footer: some View {
        HStack {
            if !stack.ordered.isEmpty, stack.remainingCount == 0 {
                Label(String(localized: "All pasted. Copy more, or close the stack."), systemImage: "checkmark.circle")
            } else if stack.isTapActive, !stack.isNextReady {
                Label(String(localized: "Preparing the next item…"), systemImage: "hourglass")
            } else if stack.isTapActive {
                Label(String(localized: "Press ⌘V in any app to paste the next item"), systemImage: "keyboard")
            } else {
                Label(String(localized: "Click an item to copy it, then press ⌘V"), systemImage: "cursorarrow.click")
            }
            Spacer()
            if !stack.ordered.isEmpty {
                Button(String(localized: "Clear")) { stack.clear() }
                    .controlSize(.small)
                    .shelfSecondaryButtonStyle()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}
