import AppKit
import ShelfCore
import SwiftUI
import UniformTypeIdentifiers

/// A list of bundle ids stored in `UserDefaults`, one form row per app, with
/// an app picker to add more. Entries ending in `*` match by prefix. Place it
/// directly in a `Section`.
struct AppListEditor: View {
    let key: String
    let seeds: [String]
    @State private var entries: [String] = []

    var body: some View {
        ForEach(entries, id: \.self) { bundleID in
            AppListRow(bundleID: bundleID) { remove(bundleID) }
        }
        HStack {
            Button { addApp() } label: {
                Label(String(localized: "Add App…"), systemImage: "plus")
            }
            Spacer()
            Button(String(localized: "Reset")) { save(seeds) }
                .disabled(entries == seeds)
        }
        .buttonStyle(.borderless)
        .onAppear { entries = UserDefaults.standard.stringArray(forKey: key) ?? seeds }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        save(entries + added.filter { !entries.contains($0) })
    }

    private func remove(_ bundleID: String) {
        save(entries.filter { $0 != bundleID })
    }

    private func save(_ list: [String]) {
        withAnimation(.smooth(duration: 0.2)) { entries = list }
        UserDefaults.standard.set(list, forKey: key)
    }
}

/// An app's icon and name, with its bundle id underneath and a remove button on hover.
struct AppListRow: View {
    let bundleID: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = AppIcons.icon(for: bundleID) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppIcons.appName(for: bundleID))
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            .help(String(localized: "Remove app"))
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(String(localized: "Remove app"), systemImage: "minus.circle", action: remove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: String(localized: "Remove app"), remove)
    }
}
