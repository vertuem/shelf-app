import ShelfCore
import SwiftUI

struct GeneralPane: View {
    let backend: any SettingsBackend

    @AppStorage(PrefKey.showInMenuBar) private var showInMenuBar = false
    @AppStorage(PrefKey.shelfPosition) private var shelfPosition = ShelfPosition.bottom.rawValue
    @AppStorage(PrefKey.cardColors) private var cardColors = CardColorMode.app.rawValue
    @AppStorage(PrefKey.copySound) private var copySound = false
    @AppStorage(PrefKey.pasteSound) private var pasteSound = true
    @AppStorage(PrefKey.pasteMode) private var pasteMode = PasteMode.toActiveApp.rawValue
    @AppStorage(PrefKey.restorePreviousClipboard) private var restorePrevious = false
    @AppStorage(PrefKey.alwaysPastePlainText) private var alwaysPlain = false
    @AppStorage(PrefKey.keepHistory) private var keepHistory = RetentionPeriod.month.rawValue

    @State private var launchAtLogin = false
    @State private var accessibilityGranted = true
    @State private var clipboardAccess = ClipboardAccess.allowed
    @State private var statistics: Store.Statistics?
    @State private var confirmingErase = false
    @State private var isWorking = false

    var body: some View {
        SettingsForm {
            PaneHeader(pane: .general)

            // What Shelf needs, and why: the same checklist as the welcome tour,
            // so a permission skipped there stays visible here.
            SettingsSection(String(localized: "Permissions")) {
                let rows = [
                    PermissionRow.clipboard(clipboardAccess, ask: {
                        backend.requestClipboardAccess()
                        clipboardAccess = backend.clipboardAccess
                    }, openSettings: { backend.openClipboardSettings() }),
                    PermissionRow.accessibility(granted: accessibilityGranted) { backend.openAccessibilitySettings() },
                    PermissionRow.files,
                ]
                PermissionProgress(rows: rows.map(\.status))
                ForEach(rows.indices, id: \.self) { rows[$0] }
            }

            Section {
                Picker(String(localized: "Shelf position"), selection: $shelfPosition) {
                    ForEach(ShelfPosition.allCases, id: \.rawValue) { position in
                        Label(position.displayName, systemImage: position.symbol).tag(position.rawValue)
                    }
                }
                Footnote(ShelfPosition(rawValue: shelfPosition)?.detail ?? "")
                Picker(String(localized: "Card colors"), selection: $cardColors) {
                    Text(String(localized: "From the app icon")).tag(CardColorMode.app.rawValue)
                    Text(String(localized: "By content type")).tag(CardColorMode.type.rawValue)
                }
            } header: {
                SectionHeader(String(localized: "Shelf"))
            }

            Section {
                Toggle(String(localized: "Open at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        backend.launchAtLogin = newValue
                        launchAtLogin = backend.launchAtLogin
                    }
                ))
                SettingToggle(
                    String(localized: "Show in menu bar"),
                    detail: showInMenuBar ? nil : String(localized: "\(Brand.name) keeps running. Use the shortcut to open the shelf, or open \(Brand.name) from Spotlight to get back here."),
                    isOn: $showInMenuBar
                )
                // Without a Dock or menu bar icon this is the visible way out; ⌘Q works here too.
                LabeledContent {
                    Button(String(localized: "Quit \(Brand.name)")) { backend.quit() }
                } label: {
                    Text(String(localized: "Quit"))
                    Text(String(localized: "Open \(Brand.name) from Spotlight to start it again."))
                }
            }

            SettingsSection(String(localized: "Sounds")) {
                SoundToggle(
                    title: String(localized: "Play a sound when you copy"),
                    detail: String(localized: "A soft tick each time something you copy is saved."),
                    isOn: $copySound
                ) { backend.playSound(.copy) }
                SoundToggle(
                    title: String(localized: "Play a sound when you paste"),
                    detail: String(localized: "A soft pop when you paste or copy a card from the shelf."),
                    isOn: $pasteSound
                ) { backend.playSound(.paste) }
            }

            SettingsSection(String(localized: "Pasting")) {
                Picker(String(localized: "Paste items"), selection: $pasteMode) {
                    Text(String(localized: "To active app")).tag(PasteMode.toActiveApp.rawValue)
                    Text(String(localized: "To clipboard")).tag(PasteMode.toClipboard.rawValue)
                }
                .disabled(!accessibilityGranted)
                Toggle(String(localized: "Restore previous clipboard after paste"), isOn: $restorePrevious)
                Toggle(String(localized: "Always paste as plain text"), isOn: $alwaysPlain)
            }

            Section {
                AppListEditor(key: PrefKey.manualPasteApps, seeds: Seeds.manualPasteApps)
            } header: {
                SectionHeader(String(localized: "Paste manually in"))
            } footer: {
                Footnote(String(localized: "Terminals, virtual machines and remote desktops often drop a simulated ⌘V. In these apps \(Brand.name) copies the item and asks you to press ⌘V."))
            }

            SettingsSection(String(localized: "History")) {
                RetentionSlider(selection: $keepHistory)
                LabeledContent(String(localized: "Erase history")) {
                    Button(String(localized: "Erase…"), role: .destructive) { confirmingErase = true }
                        .disabled(isWorking)
                }
            }

            SettingsSection(String(localized: "Storage")) {
                LabeledContent(String(localized: "Disk usage")) {
                    if let statistics {
                        Text(String(localized: "\(statistics.historyCount) items, \(Formatters.byteCount(statistics.databaseBytes + statistics.blobBytes))"))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent(String(localized: "Images older than a month")) {
                    Button(String(localized: "Remove \(statistics?.oldImageCount ?? 0) Images")) {
                        Task {
                            isWorking = true
                            _ = await backend.removeOldImages()
                            await refresh()
                            isWorking = false
                        }
                    }
                    .disabled((statistics?.oldImageCount ?? 0) == 0 || isWorking)
                }
                LabeledContent(String(localized: "Backup")) {
                    HStack(spacing: 8) {
                        Button(String(localized: "Export…")) { Task { await backend.exportHistory() } }
                        Button(String(localized: "Import…")) {
                            Task {
                                await backend.importHistory()
                                await refresh()
                            }
                        }
                    }
                }
                if backend.maccyDatabaseFound {
                    LabeledContent(String(localized: "Maccy history")) {
                        Button(String(localized: "Import from Maccy…")) {
                            Task {
                                await backend.importFromMaccy()
                                await refresh()
                            }
                        }
                    }
                }
                if backend.pasteDatabaseFound {
                    LabeledContent(String(localized: "Paste history")) {
                        Button(String(localized: "Import from Paste…")) {
                            Task {
                                await backend.importFromPaste()
                                await refresh()
                            }
                        }
                    }
                }
            }
        }
        .task {
            launchAtLogin = backend.launchAtLogin
            await refresh()
        }
        .task {
            // Permissions can change in System Settings while this pane is open.
            while !Task.isCancelled {
                accessibilityGranted = backend.isAccessibilityGranted
                clipboardAccess = backend.clipboardAccess
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .confirmationDialog(String(localized: "Erase clipboard history?"), isPresented: $confirmingErase) {
            Button(String(localized: "Erase History, Keep Pinned Items"), role: .destructive) { erase(keepPinned: true) }
            Button(String(localized: "Erase Everything"), role: .destructive) { erase(keepPinned: false) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This cannot be undone. The encryption key is replaced, so copies of old files cannot be read either."))
        }
    }

    private func erase(keepPinned: Bool) {
        Task {
            isWorking = true
            await backend.eraseHistory(keepPinned: keepPinned)
            await refresh()
            isWorking = false
        }
    }

    private func refresh() async {
        statistics = await backend.statistics()
    }
}

extension ShelfPosition {
    public var displayName: String {
        switch self {
        case .bottom: String(localized: "Bottom of the screen")
        case .left: String(localized: "Left edge")
        case .right: String(localized: "Right edge")
        case .center: String(localized: "Center of the screen")
        }
    }

    public var symbol: String {
        switch self {
        case .bottom: "rectangle.bottomthird.inset.filled"
        case .left: "rectangle.leadingthird.inset.filled"
        case .right: "rectangle.trailingthird.inset.filled"
        case .center: "rectangle.center.inset.filled"
        }
    }

    var detail: String {
        switch self {
        case .bottom: String(localized: "A row of cards along the bottom edge. ← and → move between cards.")
        case .left, .right: String(localized: "A column of cards up the screen edge. ↑ and ↓ move between cards.")
        case .center: String(localized: "A floating panel in the middle, like Spotlight, with cards in a grid. The arrows move in every direction.")
        }
    }
}

/// Day, Week, Month, Year, Forever.
struct RetentionSlider: View {
    @Binding var selection: String
    private let periods = RetentionPeriod.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "Keep history"))
                Spacer()
                Text(RetentionPeriod(rawValue: selection)?.displayName ?? "")
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Slider(
                value: Binding(
                    get: { Double(index) },
                    set: { selection = periods[Int($0.rounded())].rawValue }
                ),
                in: 0...Double(periods.count - 1),
                step: 1
            ) {
                Text(String(localized: "Keep history"))
            }
            // Without this, the grouped form puts the slider in the value
            // column, half a row away from the labels under it.
            .labelsHidden()
            .accessibilityValue(RetentionPeriod(rawValue: selection)?.displayName ?? "")
            TickLabels(titles: periods.map(\.displayName), selected: index)
                .accessibilityHidden(true)
        }
    }

    private var index: Int {
        periods.firstIndex { $0.rawValue == selection } ?? 2
    }
}

/// One label under each tick of a stepped slider: the end labels flush with
/// the slider's ends, the others centered on their tick.
private struct TickLabels: View {
    let titles: [String]
    let selected: Int
    /// The slider's ticks are inset by half the knob's width.
    private let tickInset: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let span = geometry.size.width - tickInset * 2
            ForEach(titles.indices, id: \.self) { index in
                let tick = tickInset + span * CGFloat(index) / CGFloat(max(1, titles.count - 1))
                Text(titles[index])
                    .font(.caption)
                    .foregroundStyle(index == selected ? .primary : .secondary)
                    .fixedSize()
                    .frame(width: geometry.size.width, alignment: alignment(for: index))
                    .offset(x: index == 0 || index == titles.count - 1 ? 0 : tick - geometry.size.width / 2)
            }
        }
        .frame(height: 16)
    }

    private func alignment(for index: Int) -> Alignment {
        if index == 0 { return .leading }
        if index == titles.count - 1 { return .trailing }
        return .center
    }
}

/// A sound setting: its switch, and a button to hear the sound first.
struct SoundToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: preview) {
                Image(systemName: "play.circle")
                    .font(.system(size: 17))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Play the sound"))
            .accessibilityLabel(String(localized: "Play the sound"))
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}
