import AppKit
import CryptoKit
import Observation
import ShelfCore

/// The built-in updater: GitHub Releases in, a verified and notarized app out.
///
/// No third dependency, no appcast, no signing key to manage. On launch and every six hours it reads the releases of the
/// repository, picks the newest eligible one, and offers it with its notes.
/// Installing downloads the DMG over HTTPS from GitHub, checks it against the
/// release's SHA-256 sums, verifies the DMG and the app inside with `codesign`
/// and `spctl`, pins the Team ID and bundle id to this app's own, copies the
/// new app next to the current one, and swaps them on relaunch. The old app is
/// kept until the new one has started, and restored if it does not.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case disabled(String)
        case checking
        case upToDate(Date)
        case available(Release)
        case downloading(Release)
        case verifying(Release)
        case ready(Release, stagedApp: URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    var onUpdateAvailable: ((Release) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored let currentVersion: SemanticVersion
    @ObservationIgnored let bundleIdentifier: String
    @ObservationIgnored let teamIdentifier: String?

    static let checkInterval: Duration = .seconds(6 * 3_600)

    init(preferences: Preferences, bundle: Bundle = .main) {
        self.preferences = preferences
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["Accept": "application/vnd.github+json", "User-Agent": Brand.name]
        session = URLSession(configuration: configuration)
        currentVersion = SemanticVersion(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")
            ?? SemanticVersion("0.0.0")!
        bundleIdentifier = bundle.bundleIdentifier ?? Brand.devBundleID
        teamIdentifier = CodeSignature.currentTeamIdentifier
        if let reason = disabledReason {
            state = .disabled(reason)
        }
    }

    /// How a copy of the app updates.
    enum Mode: Equatable {
        /// A local development build: never updates, and says so.
        case off
        /// A release Apple did not sign (no Developer ID): it cannot verify an
        /// update the way `install` requires, so it checks, offers the new
        /// version and downloads it; the user drags it to Applications.
        case notify
        /// A Developer ID release: verifies, installs and relaunches.
        case install
    }

    static func mode(bundleIdentifier: String, teamIdentifier: String?) -> Mode {
        if bundleIdentifier.hasSuffix(".dev") { return .off }
        return teamIdentifier == nil ? .notify : .install
    }

    var mode: Mode { Self.mode(bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier) }

    var isDevelopmentBuild: Bool { mode == .off }

    /// Development builds never update.
    var disabledReason: String? {
        mode == .off ? String(localized: "Development build: updates are off.") : nil
    }

    var isDisabled: Bool { disabledReason != nil }

    func start() {
        guard !isDisabled, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.preferences.defaults.bool(forKey: PrefKey.checkForUpdates) {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard !isDisabled else { return }
        switch state {
        case .checking, .downloading, .verifying: return
        default: break
        }
        state = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/\(Brand.repository)/releases?per_page=20")!
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
            let releases = try Release.decodeList(data)
            preferences.defaults.set(Date().timeIntervalSince1970, forKey: PrefKey.lastUpdateCheck)
            let candidate = UpdatePolicy.candidate(
                from: releases,
                current: currentVersion,
                includeBetas: preferences.defaults.bool(forKey: PrefKey.includeBetas),
                applyStabilityBuffer: !userInitiated && preferences.defaults.bool(forKey: PrefKey.stabilityBuffer),
                skippedVersion: userInitiated ? nil : preferences.defaults.string(forKey: PrefKey.skippedVersion)
            )
            if let candidate {
                state = .available(candidate)
                onUpdateAvailable?(candidate)
            } else {
                state = .upToDate(Date())
            }
        } catch {
            Log.update.error("Update check failed: \(String(describing: error), privacy: .public)")
            state = userInitiated ? .failed(String(localized: "Could not reach GitHub.")) : .idle
        }
    }

    func skip(_ release: Release) {
        preferences.defaults.set(release.tagName, forKey: PrefKey.skippedVersion)
        state = .upToDate(Date())
    }

    // MARK: Installing

    enum UpdateError: Error, LocalizedError {
        case server, untrustedURL, checksumMismatch, signature(String), notWritable, mountFailed, noApp, notNewer

        var errorDescription: String? {
            switch self {
            case .server: String(localized: "GitHub did not answer.")
            case .untrustedURL: String(localized: "The download was not hosted on GitHub.")
            case .checksumMismatch: String(localized: "The download does not match the published checksum.")
            case .signature(let detail): String(localized: "The update failed signature checks (\(detail)).")
            case .notWritable: String(localized: "Cannot write next to the app. Move \(Brand.name) to Applications and try again.")
            case .mountFailed: String(localized: "Could not open the disk image.")
            case .noApp: String(localized: "The disk image does not contain \(Brand.name).")
            case .notNewer: String(localized: "The download is not newer than this version.")
            }
        }
    }

    /// For `.notify` copies: the disk image opens in the browser's downloads,
    /// or the release page when there is no trusted image.
    func download(_ release: Release) {
        if let dmg = release.dmg, UpdatePolicy.isTrustedDownloadURL(dmg.browserDownloadURL) {
            NSWorkspace.shared.open(dmg.browserDownloadURL)
        } else {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    func install(_ release: Release) async {
        guard mode == .install, let dmg = release.dmg else { return }
        state = .downloading(release)
        do {
            guard UpdatePolicy.isTrustedDownloadURL(dmg.browserDownloadURL) else { throw UpdateError.untrustedURL }
            let (downloaded, _) = try await session.download(from: dmg.browserDownloadURL)
            let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let dmgURL = workDirectory.appendingPathComponent(dmg.name)
            try FileManager.default.moveItem(at: downloaded, to: dmgURL)

            state = .verifying(release)
            try await verifyChecksum(of: dmgURL, release: release)
            let staged = try await Task.detached(priority: .userInitiated) { [bundleIdentifier, teamIdentifier, currentVersion] in
                try Self.verifyAndStage(dmgURL: dmgURL, bundleIdentifier: bundleIdentifier,
                                        teamIdentifier: teamIdentifier, currentVersion: currentVersion)
            }.value
            state = .ready(release, stagedApp: staged)
        } catch {
            Log.update.error("Update failed: \(String(describing: error), privacy: .public)")
            state = .failed((error as? LocalizedError)?.errorDescription ?? String(localized: "The update could not be installed."))
        }
    }

    /// Every release publishes SHA-256 sums; a missing or mismatched entry stops the update.
    private func verifyChecksum(of dmgURL: URL, release: Release) async throws {
        guard let sums = release.checksums, UpdatePolicy.isTrustedDownloadURL(sums.browserDownloadURL) else {
            throw UpdateError.checksumMismatch
        }
        let (data, _) = try await session.data(from: sums.browserDownloadURL)
        guard let expected = UpdatePolicy.expectedChecksum(in: String(decoding: data, as: UTF8.self), for: dmgURL.lastPathComponent) else {
            throw UpdateError.checksumMismatch
        }
        let actual = try await Task.detached(priority: .userInitiated) {
            try SHA256.hash(data: Data(contentsOf: dmgURL, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        }.value
        guard actual == expected else { throw UpdateError.checksumMismatch }
    }

    /// Verifies the DMG and the app inside it, then copies the app next to the running one.
    nonisolated static func verifyAndStage(
        dmgURL: URL,
        bundleIdentifier: String,
        teamIdentifier: String?,
        currentVersion: SemanticVersion
    ) throws -> URL {
        guard let teamIdentifier else { throw UpdateError.signature("no team") }
        guard try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", dmgURL.path]).status == 0 else {
            throw UpdateError.signature("codesign dmg")
        }
        guard try Shell.run("/usr/sbin/spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", dmgURL.path]).status == 0 else {
            throw UpdateError.signature("spctl dmg")
        }

        let attach = try Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmgURL.path])
        guard attach.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: attach.standardOutput, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else { throw UpdateError.mountFailed }
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint]) }

        let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else { throw UpdateError.noApp }
        let mountedApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)

        guard try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", mountedApp.path]).status == 0,
              try Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", mountedApp.path]).status == 0,
              CodeSignature.validate(bundleAt: mountedApp, teamIdentifier: teamIdentifier, bundleIdentifier: bundleIdentifier)
        else { throw UpdateError.signature("app") }

        let newVersion = (Bundle(url: mountedApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(SemanticVersion.init)
        guard let newVersion, newVersion > currentVersion else { throw UpdateError.notNewer }

        let currentApp = Bundle.main.bundleURL
        let staged = currentApp.deletingLastPathComponent().appendingPathComponent(".\(Brand.name)-\(newVersion).app")
        guard FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path) else { throw UpdateError.notWritable }
        try? FileManager.default.removeItem(at: staged)
        guard try Shell.run("/usr/bin/ditto", [mountedApp.path, staged.path]).status == 0 else { throw UpdateError.notWritable }
        return staged
    }

    /// Quits and lets a small script swap the bundles, launch the new app, and
    /// roll back if the new app is not running 15 seconds later.
    func relaunch(into stagedApp: URL, paths: AppPaths) throws {
        let currentApp = Bundle.main.bundleURL
        let backup = Self.previousVersions(in: paths).appendingPathComponent(currentApp.lastPathComponent)
        let script = """
            #!/bin/bash
            PID="$1"; CURRENT="$2"; NEW="$3"; BACKUP="$4"
            while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
            mkdir -p "$(dirname "$BACKUP")"
            rm -rf "$BACKUP"
            mv "$CURRENT" "$BACKUP" || exit 1
            if ! mv "$NEW" "$CURRENT"; then mv "$BACKUP" "$CURRENT"; open "$CURRENT"; exit 1; fi
            open "$CURRENT" --args --updated-from "$BACKUP"
            sleep 15
            if ! pgrep -f "$CURRENT/Contents/MacOS/" >/dev/null; then
              rm -rf "$CURRENT"; mv "$BACKUP" "$CURRENT"; open "$CURRENT"
            fi
            """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-swap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "\(ProcessInfo.processInfo.processIdentifier)", currentApp.path, stagedApp.path, backup.path]
        try process.run()
        NSApp.terminate(nil)
    }

    /// The previous bundle is kept for one launch after an update, then removed.
    /// Where the replaced app waits until the new one has started.
    static func previousVersions(in paths: AppPaths) -> URL {
        paths.root.appendingPathComponent("Previous Version", isDirectory: true)
    }

    /// `previousVersions` is the only folder whose apps may be deleted: the
    /// path arrives as a launch argument, so anything else is left alone.
    static func cleanUpAfterUpdate(arguments: [String], preferences: Preferences, previousVersions: URL) {
        let defaults = preferences.defaults
        if let index = arguments.firstIndex(of: "--updated-from"), index + 1 < arguments.count {
            defaults.set(arguments[index + 1], forKey: PrefKey.previousBundlePath)
            defaults.set(1, forKey: PrefKey.launchesSinceUpdate)
            return
        }
        guard let path = defaults.string(forKey: PrefKey.previousBundlePath) else { return }
        let launches = defaults.integer(forKey: PrefKey.launchesSinceUpdate) + 1
        if launches >= 2 {
            let old = URL(fileURLWithPath: path).standardizedFileURL
            if old.pathExtension == "app",
               old.deletingLastPathComponent().path == previousVersions.standardizedFileURL.path {
                try? FileManager.default.removeItem(at: old)
            }
            defaults.removeObject(forKey: PrefKey.previousBundlePath)
            defaults.removeObject(forKey: PrefKey.launchesSinceUpdate)
        } else {
            defaults.set(launches, forKey: PrefKey.launchesSinceUpdate)
        }
    }

    var statusText: String {
        switch state {
        case .idle: String(localized: "Not checked yet")
        case .disabled(let reason): reason
        case .checking: String(localized: "Checking…")
        case .upToDate: String(localized: "\(Brand.name) is up to date.")
        case .available(let release): String(localized: "Version \(release.version?.description ?? release.tagName) is available.")
        case .downloading: String(localized: "Downloading…")
        case .verifying: String(localized: "Verifying signature and notarization…")
        case .ready: String(localized: "Ready. Relaunch to finish.")
        case .failed(let message): message
        }
    }
}
