import AppKit
import ShelfCore
import SwiftUI

struct AboutPane: View {
    let backend: any SettingsBackend
    @AppStorage(PrefKey.checkForUpdates) private var checkAutomatically = true
    @AppStorage(PrefKey.includeBetas) private var includeBetas = false
    @AppStorage(PrefKey.stabilityBuffer) private var stabilityBuffer = false

    var body: some View {
        SettingsForm {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 112, height: 112)
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    Text(Brand.name)
                        .font(.largeTitle.weight(.bold))
                    Text(backend.versionString)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if backend.isDevelopmentBuild {
                        Text(String(localized: "Development build"))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.yellow, in: Capsule())
                            .foregroundStyle(.black)
                            .help(String(localized: "Ad-hoc signed. The updater is off; build from source to update."))
                    }
                    Text(String(localized: "The Paste shelf, native, open source, no subscription."))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                LabeledContent {
                    Button(String(localized: "Check for Updates")) { backend.checkForUpdates() }
                        .disabled(backend.isDevelopmentBuild || backend.isCheckingForUpdates)
                } label: {
                    Text(String(localized: "Status"))
                    HStack(spacing: 6) {
                        if backend.isCheckingForUpdates { ProgressView().controlSize(.mini) }
                        Text(backend.updateStatus)
                    }
                }
                Toggle(String(localized: "Check for updates automatically"), isOn: $checkAutomatically)
                Toggle(String(localized: "Include betas"), isOn: $includeBetas)
                Toggle(String(localized: "Wait three days after a release"), isOn: $stabilityBuffer)
            } header: {
                SectionHeader(String(localized: "Updates"))
            } footer: {
                if backend.updatesInstallByHand {
                    Footnote(String(localized: "Updates come from GitHub Releases. This copy is not signed by Apple, so \(Brand.name) tells you when a new version is out and downloads it; you drag it to Applications."))
                } else {
                    Footnote(String(localized: "Updates come from GitHub Releases. Each download is checked for the developer's signature and Apple's notarization before it replaces the app, and the previous version is kept until the new one starts."))
                }
            }

            SettingsSection(String(localized: "Help")) {
                LabeledContent(String(localized: "Welcome tour")) {
                    Button(String(localized: "Show Again")) { backend.rerunOnboarding() }
                }
                LabeledContent {
                    Button(String(localized: "Report a Crash…")) { backend.reportCrash() }
                } label: {
                    Text(String(localized: "Something crashed?"))
                    Text(String(localized: "Copies the last crash log to the clipboard and opens a new GitHub issue. Crash logs never contain clipboard content. Nothing is sent unless you submit the issue."))
                }
            }

            SettingsSection(String(localized: "Open Source")) {
                Link(destination: Brand.repositoryURL) {
                    Label(String(localized: "Source code on GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: Brand.repositoryURL.appendingPathComponent("blob/main/LICENSE")) {
                    Label(String(localized: "MIT License"), systemImage: "doc.text")
                }
                DisclosureGroup(String(localized: "Acknowledgements")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GRDB.swift by Gwendal Roué, MIT License")
                        Text("KeyboardShortcuts by Sindre Sorhus, MIT License")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}
