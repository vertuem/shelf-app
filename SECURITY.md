# Security

Shelf sees everything you copy, so security problems are treated as the most urgent kind of bug.

## Reporting a vulnerability

Report privately through GitHub: on the repository, open **Security**, then **Report a vulnerability**. Please do not open a public issue.

- **Response:** within 72 hours.
- **Credit:** in the release notes, unless you would rather stay anonymous.
- **Serious issues** that expose clipboard data get an emergency release, pushed through the in-app updater, and a public post-mortem.

## Design

Shelf is not sandboxed, because pasting with a simulated ⌘V and the Paste Stack's event tap need Accessibility, which the App Sandbox forbids. Every other protection is turned up to compensate.

| Threat | Mitigation |
|---|---|
| Another local user, or someone with the disk, reads the history | Blobs and thumbnails are sealed with ChaChaPoly, using a 256-bit key in the login Keychain, which your login password protects. Like any keychain item, the key travels with keychain backups and Migration Assistant; a copy of the data folder alone is only ciphertext. The data folder is mode 0700 and the database 0600. "Erase history" rotates the key. |
| Passwords are captured | Concealed, transient and auto-generated copies are rejected before their content is read: only the list of pasteboard types, and then the name of the app the pasteboard declares, are looked at first. While capture is paused, or macOS would ask about every read, nothing on the pasteboard is touched. Copies from Keychain Access, Passwords, 1Password, Bitwarden, KeePassXC, Strongbox, Proton Pass and Enpass are ignored, including when you switch apps right after copying; other password managers rely on marking their copies as concealed, which most do. Putting your clipboard back after a paste is never recorded as a copy. An optional "Detect secrets" heuristic skips strings that look like keys or tokens. |
| History is visible on a shared screen | The shelf and the Paste Stack use `sharingType = .none` unless you allow screen sharing. |
| A malicious update | See [The updater](#the-updater) below. |
| Supply chain | Two dependencies, both MIT, pinned to an exact version with checksums in `Package.resolved`. Dependabot and a weekly OSV scan watch them. There are no build plugins or post-install scripts. |
| Crash logs leak content | `ClipItem` and the other model types print only an id and a kind. Logs never contain previews, URLs or paths. Shelf sends no crash reports; "Report a Crash…" copies the log for you to submit yourself. |
| Link previews deanonymize you or probe your network | Off by default. When on: http and https only, a 5 second timeout, and never for links from ignored apps. Never for hosts that are, or resolve to, loopback, private, link-local or multicast addresses, in any spelling (`127.1`, `0x7f.0.0.1`, `localhost.`). |
| A crafted backup zip reads local files | Paths inside an imported archive must stay inside the archive, symlinks included. |
| Decrypted copies linger | Quick Look previews are written to one temporary folder, emptied at launch, on quit and on "Erase history". Files received for pending-file cards are deleted with their card. |
| The event tap is abused | It exists only while the Paste Stack panel is open, inspects only Command+V key-downs, and passes every event through unchanged. It is an active tap rather than a listen-only one only so the next item is on the clipboard before the app receives ⌘V; it never drops or changes an event. |
| The Accessibility prompt is used for social engineering | Onboarding explains in plain words what the permission is for and what it is not used for. Shelf works fully without it, in "to clipboard" mode. |

**What is stored unencrypted:** the search index, which holds the first 500 characters of each text item, card titles, the text recognized in images, the source app name, URLs and file paths. This keeps search instant. The Privacy settings pane says so, and the option to turn off sealing for speed is there too.

**Text in images:** recognition runs on this Mac with Apple's Vision framework, and nothing is sent anywhere. Words that look like keys, tokens or passwords are dropped from the recognized text before it is stored, whether or not "Detect secrets" is on, so a screenshot of a password field or an API key does not end up in the search index or in "Copy for AI". Turn "Recognize text in images" off in Privacy settings to keep no image text at all.

**Permissions, and why:**

| Permission | Why | Without it |
|---|---|---|
| Paste from Other Apps (macOS 15.4 and later) | Shelf reads the clipboard after each copy to keep the history. | Nothing is recorded. |
| Accessibility (optional) | Shelf presses ⌘V for you in the app you were using, and the Paste Stack watches for ⌘V while it is open. | Shelf copies the card and you press ⌘V. |
| Desktop, Documents, Downloads, external and network drives (asked by macOS on first use) | Reading the files you copy, to show a preview and paste them back. | File cards show the file's name and icon only. |
| Login item | Opening at login, since there is no Dock or menu bar icon. | Open Shelf yourself after a restart. |

Shelf never asks for Full Disk Access, Screen Recording or Input Monitoring. The welcome tour and Settings, General show each permission's status.

**Entitlements:** hardened runtime with no exceptions, and library validation on.

## The updater

The updater:

1. Downloads only over HTTPS from github.com.
2. Checks the DMG against the release's SHA-256 sums. A release without a matching sum is not installed.
3. Verifies the DMG and the app inside with `codesign --verify --deep --strict` and `spctl --assess`.
4. Requires the app's Developer ID Team ID and bundle ID to match the running app's.
5. Keeps the previous app until the new one has started, and restores it automatically if the new one does not stay running.

Development and ad-hoc builds never update themselves.

## What is never collected

No analytics, no telemetry, no crash reporting, no accounts. The only network traffic is:

- update checks against the GitHub API, which can be turned off in About
- link previews, if you turn them on
