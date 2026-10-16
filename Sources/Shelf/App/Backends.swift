import AppKit
import ServiceManagement
import ShelfCapture
import ShelfCore
import ShelfPaste
import ShelfUI
import UniformTypeIdentifiers

// MARK: - Settings

extension AppServices: SettingsBackend {
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.ui.error("Login item change failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    var isAccessibilityGranted: Bool { SystemAccessibility().isTrusted }

    /// macOS 15.4 and later ask before an app reads the clipboard by itself.
    var clipboardAccess: ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        return switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: .allowed
        case .ask: .asks
        case .alwaysDeny: .denied
        default: .notAskedYet
        }
    }

    /// Reading the clipboard once makes macOS show its alert now, during
    /// onboarding, instead of at the first copy.
    func requestClipboardAccess() {
        _ = NSPasteboard.general.types
        _ = NSPasteboard.general.string(forType: .string)
    }

    /// On in Login Items; before the first registration (end of the welcome
    /// tour), "after setup"; otherwise off.
    var loginItemState: LoginItemState {
        if launchAtLogin { return .on }
        return preferences.defaults.bool(forKey: PrefKey.loginItemRegistered) ? .off : .afterSetup
    }

    func turnOnLoginItem() {
        launchAtLogin = true
    }

    /// Privacy & Security, where Paste from Other Apps is listed.
    func openClipboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        SystemAccessibility.prompt()
        SystemAccessibility.openSettings()
    }

    func statistics() async -> Store.Statistics? {
        try? await store.statistics()
    }

    func eraseHistory(keepPinned: Bool) async {
        removePreviewFiles()
        do {
            try await store.eraseHistory(keepPinned: keepPinned)
        } catch {
            hud.show(String(localized: "History could not be erased"), symbol: "exclamationmark.triangle")
        }
    }

    func removeOldImages() async -> Int {
        (try? await store.removeImages(olderThan: Date().addingTimeInterval(-30 * 86_400))) ?? 0
    }

    func exportHistory() async {
        let warning = NSAlert()
        warning.messageText = String(localized: "The export is not encrypted")
        warning.informativeText = String(localized: "Anyone with the file can read everything in it, including items you pinned. Keep it somewhere safe.")
        warning.addButton(withTitle: String(localized: "Continue"))
        warning.addButton(withTitle: String(localized: "Cancel"))
        guard warning.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "\(Brand.name) History \(day).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try await HistoryArchive.export(store: store, to: url, appVersion: versionString)
            hud.show(String(localized: "Exported \(manifest.itemCount) items"), symbol: "square.and.arrow.up")
        } catch {
            hud.show(String(localized: "Export failed"), symbol: "exclamationmark.triangle")
        }
    }

    func importHistory() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try await HistoryArchive.importArchive(from: url, into: store)
            hud.show(String(localized: "Imported \(result.imported) items"), symbol: "square.and.arrow.down")
        } catch {
            hud.show(String(localized: "This file is not a \(Brand.name) export"), symbol: "exclamationmark.triangle")
        }
    }

    var maccyDatabaseFound: Bool { MaccyDatabase.url != nil }

    func importFromMaccy() async {
        guard let url = MaccyDatabase.url else { return }
        await runMaccyImport(from: url)
    }

    var pasteDatabaseFound: Bool { PasteDatabase.url != nil }

    /// Asks first, naming the count, as the Maccy offer does: an import of a
    /// large history is slow and adds every item to the Clipboard tab.
    func importFromPaste() async {
        guard let url = PasteDatabase.url else { return }
        let count = PasteDatabase.itemCount(at: url) ?? 0
        let alert = NSAlert()
        alert.messageText = String(localized: "Import your Paste history?")
        alert.informativeText = String(localized: "\(Brand.name) found \(count) items in Paste. Importing copies them; Paste keeps its own history. Pinboards come along as pinboards.")
        alert.addButton(withTitle: String(localized: "Import"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await runPasteImport(from: url)
    }

    var isDevelopmentBuild: Bool { updater.isDisabled }
    var updateStatus: String { updater.statusText }

    var isCheckingForUpdates: Bool {
        switch updater.state {
        case .checking, .downloading, .verifying: true
        default: false
        }
    }

    func checkForUpdates() {
        Task {
            await updater.check(userInitiated: true)
            if case .available(let release) = updater.state {
                updateWindow.show(release)
            }
        }
    }

    func rerunOnboarding() {
        onboardingWindow.show()
    }

    func reportCrash() {
        CrashReporter.report(version: versionString)
    }
}

// MARK: - Onboarding

extension AppServices: OnboardingBackend {
    func requestAccessibility() {
        openAccessibilitySettings()
    }

    var runningClipboardManagers: [String] {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        var names: [String] = []
        for (pattern, name) in Seeds.otherClipboardManagers where running.contains(where: { AppList.matches($0, in: [pattern]) }) {
            names.append(name)
        }
        for (bundleID, name) in Seeds.launchersWithClipboardHistory where running.contains(bundleID) {
            names.append(String(localized: "\(name) (if its clipboard history is on)"))
        }
        return names.sorted()
    }

    func createSnippetsPinboard() async {
        let boards = (try? await store.pinboards()) ?? []
        let name = String(localized: "Snippets")
        guard !boards.contains(where: { $0.name == name }) else { return }
        _ = try? await store.createPinboard(name: name, color: .orange, icon: "star")
    }

    func finishOnboarding(accessibilitySkipped: Bool) {
        let firstTime = !preferences.defaults.bool(forKey: PrefKey.onboardingCompleted)
        preferences.defaults.set(true, forKey: PrefKey.onboardingCompleted)
        if accessibilitySkipped, firstTime {
            preferences.pasteMode = .toClipboard
        }
        onboardingWindow.close()
        if firstTime {
            registerLoginItemOnce()
            hud.show(String(localized: "Press \(Hotkeys.display(.activateShelf)) to open \(Brand.name)"), symbol: "keyboard", duration: .seconds(4))
            offerMaccyImportIfFoundAfterOnboarding()
        }
    }

    private func offerMaccyImportIfFoundAfterOnboarding() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            launchMaccyOffer()
        }
    }
}

// MARK: - Menu bar

extension AppServices: MenuBarBackend {
    func openShelf() {
        if !shelf.isVisible { toggleShelf() }
    }

    func showCheatSheet() {
        cheatSheet.show()
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
