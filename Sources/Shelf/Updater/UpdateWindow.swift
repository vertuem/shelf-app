import AppKit
import ShelfCore
import SwiftUI

/// Offers an update with its release notes: Install, Skip This Version, Later.
@MainActor
final class UpdateWindowController {
    private var window: NSWindow?
    private let updater: Updater
    private let paths: AppPaths

    init(updater: Updater, paths: AppPaths) {
        self.updater = updater
        self.paths = paths
    }

    func show(_ release: Release) {
        let view = UpdateView(updater: updater, release: release, paths: paths) { [weak self] in self?.close() }
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Software Update")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}

struct UpdateView: View {
    let updater: Updater
    let release: Release
    let paths: AppPaths
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "A new version of \(Brand.name) is available"))
                        .font(.headline)
                    Text(String(localized: "\(release.version?.description ?? release.tagName) is available. You have \(updater.currentVersion.description)."))
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 220)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            if updater.mode == .notify {
                Text(String(localized: "This copy of \(Brand.name) is not signed by Apple, so it cannot replace itself. Download opens the disk image: drag \(Brand.name) to Applications and replace the old one. On its first start, macOS asks once more for Accessibility and for the history key in your keychain; choose Always Allow."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(updater.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                switch updater.state {
                case .ready(_, let staged):
                    Button(String(localized: "Relaunch")) { try? updater.relaunch(into: staged, paths: paths) }
                        .keyboardShortcut(.defaultAction)
                case .downloading, .verifying:
                    ProgressView().controlSize(.small)
                default:
                    Button(String(localized: "Skip This Version")) {
                        updater.skip(release)
                        close()
                    }
                    Button(String(localized: "Later"), action: close)
                        .keyboardShortcut(.cancelAction)
                    if updater.mode == .notify {
                        Button(String(localized: "Download")) {
                            updater.download(release)
                            close()
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button(String(localized: "Install Update")) { Task { await updater.install(release) } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var notes: AttributedString {
        let markdown = release.body ?? ""
        return (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
