import AppKit
import Carbon.HIToolbox
import ShelfCore
@testable import ShelfPaste
import XCTest

@MainActor
final class FakeTap: CommandVTapping {
    var isInstalled = false
    var installs = 0
    var removals = 0
    var allowInstall = true

    func install() -> Bool {
        installs += 1
        isInstalled = allowInstall
        return allowInstall
    }

    func remove() {
        removals += 1
        isInstalled = false
    }
}

@MainActor
final class PasteStackTests: XCTestCase {
    var env: TestEnvironment!
    var pasteboard: NSPasteboard!
    var tap: FakeTap!
    var stack: PasteStack!

    override func setUp() async throws {
        env = TestEnvironment()
        try await env.store.open()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("shelf-stack-\(UUID().uuidString)"))
        tap = FakeTap()
        let paster = Paster(store: env.store, preferences: env.preferences, pasteboard: pasteboard,
                            keystrokes: RecordingKeystrokes(), accessibility: FakeAccessibility(isTrusted: true))
        stack = PasteStack(store: env.store, paster: paster, pasteboard: pasteboard) { [tap] _ in tap! }
    }

    override func tearDown() async throws {
        stack.close()
        pasteboard.releaseGlobally()
        env.cleanUp()
    }

    func fill(_ texts: [String]) async throws {
        for text in texts {
            stack.append(try await env.store.insert(Make.text(text)))
        }
        await stack.waitUntilPrefetched()
    }

    func testTapExistsOnlyWhileOpen() {
        XCTAssertEqual(tap.installs, 0)
        stack.open()
        XCTAssertTrue(stack.isTapActive)
        XCTAssertEqual(tap.installs, 1)
        stack.close()
        XCTAssertEqual(tap.removals, 1)
        XCTAssertFalse(tap.isInstalled)
    }

    func testPopsOldestFirst() async throws {
        stack.open()
        try await fill(["one", "two", "three"])
        for expected in ["one", "two", "three"] {
            stack.simulateCommandV()
            XCTAssertEqual(pasteboard.string(forType: .string), expected)
        }
        XCTAssertNil(stack.next)
        XCTAssertEqual(stack.remainingCount, 0)
        // Further Cmd+V passes through untouched.
        stack.simulateCommandV()
        XCTAssertEqual(pasteboard.string(forType: .string), "three")
    }

    func testCopyingAPastedItemAgainQueuesItOnce() async throws {
        stack.open()
        let first = try await env.store.insert(Make.text("A"))
        let second = try await env.store.insert(Make.text("B"))
        stack.append(first)
        stack.append(second)
        await stack.waitUntilPrefetched()
        stack.simulateCommandV() // pastes A
        stack.append(first) // A copied again
        await stack.waitUntilPrefetched()
        XCTAssertEqual(stack.ordered.map(\.preview), ["B", "A"])
        XCTAssertEqual(stack.remainingCount, 2)
        stack.simulateCommandV()
        XCTAssertEqual(pasteboard.string(forType: .string), "B")
        stack.simulateCommandV()
        XCTAssertEqual(pasteboard.string(forType: .string), "A")
        XCTAssertEqual(stack.remainingCount, 0)
    }

    func testReverseOrder() async throws {
        stack.open()
        try await fill(["one", "two", "three"])
        stack.reversed = true
        XCTAssertEqual(stack.ordered.map(\.preview), ["three", "two", "one"])
        stack.simulateCommandV()
        XCTAssertEqual(pasteboard.string(forType: .string), "three")
    }

    func testCopiesWhileOpenAreAppended() async throws {
        stack.open()
        _ = try await env.store.insert(Make.text("captured while open"))
        let appended = await wait { self.stack.items.count == 1 }
        XCTAssertTrue(appended)
        stack.close()
        _ = try await env.store.insert(Make.text("captured after close"))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(stack.items.contains { $0.preview == "captured after close" })
    }

    func testStackWritesCarryTheOriginMarker() async throws {
        stack.open()
        try await fill(["marked"])
        stack.simulateCommandV()
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType(Brand.originMarkerType)) ?? false)
    }

    func testClickFallbackWithoutAccessibility() async throws {
        tap.allowInstall = false
        stack.open()
        XCTAssertFalse(stack.isTapActive)
        try await fill(["a", "b"])
        await stack.copyByClick(stack.items[1])
        XCTAssertEqual(pasteboard.string(forType: .string), "b")
        XCTAssertEqual(stack.next?.preview, "a")
    }

    func testTapRecognizesOnlyPlainCommandV() throws {
        let code = CGKeyCode(kVK_ANSI_V)
        func event(_ flags: CGEventFlags, key: CGKeyCode = CGKeyCode(kVK_ANSI_V), repeating: Bool = false, synthetic: Bool = false) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
            if synthetic { event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.userData) }
            return event
        }
        XCTAssertTrue(CommandVTap.isPlainCommandV(event(.maskCommand), vKeyCode: code))
        XCTAssertFalse(CommandVTap.isPlainCommandV(event([.maskCommand, .maskShift]), vKeyCode: code))
        XCTAssertFalse(CommandVTap.isPlainCommandV(event([]), vKeyCode: code))
        XCTAssertFalse(CommandVTap.isPlainCommandV(event(.maskCommand, key: CGKeyCode(kVK_ANSI_C)), vKeyCode: code))
        XCTAssertFalse(CommandVTap.isPlainCommandV(event(.maskCommand, repeating: true), vKeyCode: code))
        XCTAssertFalse(CommandVTap.isPlainCommandV(event(.maskCommand, synthetic: true), vKeyCode: code))
    }
}
