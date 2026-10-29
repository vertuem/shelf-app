import ShelfCore
@testable import ShelfPaste
import XCTest

@MainActor
final class AccessibilityRecoveryTests: XCTestCase {
    var defaults: UserDefaults!
    var suite: String!
    var resets = 0
    var prompts = 0

    override func setUp() {
        suite = "accessibility-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        resets = 0
        prompts = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    @discardableResult
    func run(build: String, trusted: Bool) -> Bool {
        AccessibilityRecovery.run(defaults: defaults, build: build, isTrusted: trusted,
                                  reset: { self.resets += 1 }, prompt: { self.prompts += 1 })
    }

    func testAnUpdateThatLostTheGrantResetsAndAsksOnce() {
        run(build: "0.1.1 (5)", trusted: true)
        XCTAssertTrue(run(build: "0.1.2 (6)", trusted: false))
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(prompts, 1)
        XCTAssertFalse(run(build: "0.1.2 (6)", trusted: false), "asked once; a refusal is respected")
        XCTAssertEqual(resets, 1)
    }

    func testTurnedOffWithoutAnUpdateIsLeftAlone() {
        run(build: "0.1.1 (5)", trusted: true)
        XCTAssertFalse(run(build: "0.1.1 (5)", trusted: false))
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(prompts, 0)
    }

    func testNeverGrantedIsLeftAlone() {
        XCTAssertFalse(run(build: "0.1.1 (5)", trusted: false))
        XCTAssertEqual(resets, 0)
    }

    func testAGrantedUpdateJustRecordsTheNewBuild() {
        run(build: "0.1.1 (5)", trusted: true)
        XCTAssertFalse(run(build: "0.1.2 (6)", trusted: true))
        XCTAssertEqual(defaults.string(forKey: PrefKey.accessibilityGrantedBuild), "0.1.2 (6)")
        XCTAssertEqual(resets, 0)
    }
}
