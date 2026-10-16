import AppKit
import Carbon.HIToolbox

/// A keyboard event tap that sees Cmd+V before the target app does.
///
/// It exists only while the Paste Stack is open, inspects key-down events only,
/// reacts only to Command+V without other modifiers, and passes every event
/// through unchanged. It needs Accessibility; `install()` returns false without it.
///
/// It is a default (active) tap, not `.listenOnly`, because a listen-only tap
/// is told about the event without holding it: the app could paste before the
/// next item is on the clipboard. The callback always returns the event as is.
@MainActor
public protocol CommandVTapping: AnyObject {
    var isInstalled: Bool { get }
    func install() -> Bool
    func remove()
}

@MainActor
public final class CommandVTap: CommandVTapping {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onCommandV: () -> Void

    public init(onCommandV: @escaping () -> Void) {
        self.onCommandV = onCommandV
    }

    public var isInstalled: Bool { tap != nil }

    public func install() -> Bool {
        guard tap == nil else { return true }
        currentVKeyCode = KeyCodes.v
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: commandVTapCallback,
            userInfo: pointer
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    public func remove() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    /// Read by the callback before hopping onto the main actor.
    fileprivate nonisolated(unsafe) var currentVKeyCode = CGKeyCode(kVK_ANSI_V)

    fileprivate func handle(type: CGEventType, isCommandV: Bool) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown where isCommandV:
            onCommandV()
        default:
            break
        }
    }

    /// Command+V, no Shift, Option or Control, not a key repeat, not posted by Shelf.
    nonisolated static func isPlainCommandV(_ event: CGEvent, vKeyCode: CGKeyCode) -> Bool {
        let flags = event.flags
        guard flags.contains(.maskCommand),
              flags.isDisjoint(with: [.maskShift, .maskAlternate, .maskControl]),
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(vKeyCode),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.getIntegerValueField(.eventSourceUserData) != SyntheticEvent.userData else { return false }
        return true
    }
}

/// The C callback. The tap's run loop source is on the main run loop, so the
/// callback always runs on the main thread.
private func commandVTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let tap = Unmanaged<CommandVTap>.fromOpaque(userInfo).takeUnretainedValue()
        let isCommandV = type == .keyDown && CommandVTap.isPlainCommandV(event, vKeyCode: tap.currentVKeyCode)
        MainActor.assumeIsolated {
            tap.handle(type: type, isCommandV: isCommandV)
        }
    }
    return Unmanaged.passUnretained(event)
}
