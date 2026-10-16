import KeyboardShortcuts
import ShelfCore
import SwiftUI

struct ShortcutsPane: View {
    @AppStorage(PrefKey.quickPasteModifier) private var quickPasteModifier = QuickPasteModifier.command.rawValue
    @AppStorage(PrefKey.plainTextModifier) private var plainTextModifier = PlainTextModifier.shift.rawValue
    @State private var refresh = 0

    var body: some View {
        SettingsForm {
            PaneHeader(pane: .shortcuts)

            Section {
                KeyboardShortcuts.Recorder(String(localized: "Activate \(Brand.name)"), name: .activateShelf)
                KeyboardShortcuts.Recorder(String(localized: "Activate Paste Stack"), name: .activatePasteStack)
                KeyboardShortcuts.Recorder(String(localized: "Next pinboard"), name: .nextPinboard)
                KeyboardShortcuts.Recorder(String(localized: "Previous pinboard"), name: .previousPinboard)
                KeyboardShortcuts.Recorder(String(localized: "Pause or resume capture"), name: .togglePause)
            } footer: {
                Footnote(String(localized: "The pinboard shortcuts only work while the shelf is open."))
            }
            Section {
                Picker(String(localized: "Quick paste modifier"), selection: $quickPasteModifier) {
                    Text("⌘ " + String(localized: "Command")).tag(QuickPasteModifier.command.rawValue)
                    Text("⌥ " + String(localized: "Option")).tag(QuickPasteModifier.option.rawValue)
                    Text("⌃ " + String(localized: "Control")).tag(QuickPasteModifier.control.rawValue)
                }
                Picker(String(localized: "Plain text modifier"), selection: $plainTextModifier) {
                    Text("⇧ " + String(localized: "Shift")).tag(PlainTextModifier.shift.rawValue)
                    Text("⌥ " + String(localized: "Option")).tag(PlainTextModifier.option.rawValue)
                }
                HStack {
                    Spacer()
                    Button(String(localized: "Reset to Defaults")) {
                        Hotkeys.resetToDefaults()
                        quickPasteModifier = QuickPasteModifier.command.rawValue
                        plainTextModifier = PlainTextModifier.shift.rawValue
                        refresh += 1
                    }
                }
            } footer: {
                Footnote(String(localized: "Hold the plain text modifier while double-clicking a card or with the quick paste shortcut to paste without formatting."))
            }
            SettingsSection(String(localized: "In the shelf")) {
                ForEach(CheatSheetView.rows, id: \.action) { row in
                    LabeledContent(row.action) { KeyCaps(keys: row.keys) }
                }
            }
            .id(refresh)
        }
    }
}
