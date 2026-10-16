import AppKit
import Carbon.HIToolbox

/// Posts the synthetic Cmd+V. A protocol so tests can record instead of type.
@MainActor
public protocol KeystrokeSending {
    func sendPaste()
}

/// Marks events Shelf posts, so its own Paste Stack tap lets them through untouched.
public enum SyntheticEvent {
    /// The bytes spell "Cardsill", the product's earlier name; only uniqueness matters.
    public static let userData: Int64 = 0x4361_7264_7369_6C6C
}

/// Posts Cmd+V through the HID event tap. Requires Accessibility.
@MainActor
public final class CGEventKeystrokeSender: KeystrokeSending {
    public init() {}

    public func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys the user still holds (Shift from Shift+Enter, say) must not leak into the paste.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let key = KeyCodes.v
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        for event in [down, up] {
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.userData)
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// Key codes by character for the current layout. On Dvorak or AZERTY the
/// "V" key is not at the ANSI position, and Cmd+V is matched by character.
@MainActor
public enum KeyCodes {
    public static var v: CGKeyCode {
        keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
    }

    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &characters)
                if status == noErr, length == 1, Character(UnicodeScalar(characters[0]) ?? " ") == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
