import AppKit
import SwiftUI

/// A short message near the bottom of the screen while the shelf is closed,
/// for "Copied. Press ⌘V to paste." Never takes focus or clicks.
@MainActor
public final class ToastHUD {
    private let panel: NSPanel
    private let model = ToastHUDModel()
    private var hideTask: Task<Void, Never>?

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 60),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ToastHUDView(model: model))
    }

    public func show(_ message: String, symbol: String = "doc.on.clipboard", duration: Duration = .milliseconds(1_500)) {
        model.message = message
        model.symbol = symbol
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.minY + 80))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            let panel = self.panel
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }
        }
    }
}

@MainActor
@Observable
final class ToastHUDModel {
    var message = ""
    var symbol = "doc.on.clipboard"
}

struct ToastHUDView: View {
    let model: ToastHUDModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.symbol)
            Text(model.message)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .shelfMaterial(cornerRadius: 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
