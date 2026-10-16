import AppKit
import ShelfCapture
@testable import ShelfCore
@testable import ShelfUI
import XCTest

/// Performance budgets, enforced with a 20% tolerance. Budgets are
/// for an M1 MacBook Air running release code; CI runs this suite in a release
/// build on its own (`swift test -c release -Xswiftc -enable-testing --filter PerformanceTests`). Each test times several
/// runs and checks the median, so one slow run on a busy runner does not fail
/// the build, and reports the numbers for the PR log.
final class PerformanceTests: XCTestCase {
    static let tolerance = 1.2

    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    func assertBudget(_ name: String, samples: [Double], budget: Double, file: StaticString = #filePath, line: UInt = #line) {
        let value = median(samples)
        print("[performance] \(name): median \(String(format: "%.2f", value)) ms, budget \(budget) ms")
        XCTAssertLessThanOrEqual(value, budget * Self.tolerance, "\(name) over budget", file: file, line: line)
    }

    /// Search over 10,000 items in under 10 ms.
    func testSearchOverTenThousandItems() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        try await env.store.open()
        let words = ["invoice", "meeting", "swift", "design", "travel", "recipe", "budget", "launch", "review", "shelf"]
        let start = Date(timeIntervalSinceNow: -100_000)
        for index in 0..<10_000 {
            let text = "\(words[index % 10]) note \(index) about \(words[(index * 7) % 10]) and \(words[(index * 3) % 10])"
            var captured = Make.text(text, at: start.addingTimeInterval(Double(index)))
            captured.representations = []
            try await env.store.insert(captured)
        }
        let clock = ContinuousClock()
        var samples: [Double] = []
        for query in ["invoice", "note 42", "travel recipe", "type:text launch", "app:notes swift", "zzzz", "inv", "budget 99"] {
            let parsed = SearchQuery.parse(query)
            for _ in 0..<3 {
                let elapsed = try await clock.measure { _ = try await env.store.search(parsed, scope: .history) }
                samples.append(milliseconds(elapsed))
            }
        }
        assertBudget("search, 10,000 items", samples: samples, budget: 10)
    }

    /// Capture of a 10 KB text item in under 5 ms, off the main thread.
    func testCaptureOfTenKilobyteText() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        try await env.store.open()
        let clock = ContinuousClock()
        var samples: [Double] = []
        for run in 0..<20 {
            let text = String(repeating: "lorem ipsum \(run) ", count: 600).prefix(10_240)
            let snapshot = PasteboardSnapshot.text(String(text))
            let elapsed = try await clock.measure {
                let captured = ItemBuilder.build(from: snapshot, source: SourceApp(bundleID: "a", name: "A"), maxItemBytes: 10_000_000)
                try await env.store.insert(captured)
            }
            samples.append(milliseconds(elapsed))
        }
        assertBudget("capture, 10 KB text", samples: samples, budget: 5)
    }

    /// Capture of a 5 MB image in under 150 ms: ImageIO downsampling, never a full decode.
    func testCaptureOfFiveMegabyteImage() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        try await env.store.open()
        let png = try XCTUnwrap(Self.noisyPNG(width: 1_400, height: 1_000))
        XCTAssertGreaterThan(png.count, 4_500_000)
        let clock = ContinuousClock()
        var samples: [Double] = []
        for run in 0..<5 {
            var data = png
            data.append(UInt8(run)) // distinct hash per run
            let snapshot = PasteboardSnapshot(items: [[ClipRepresentation(uti: PasteboardTypes.png, data: data)]])
            let elapsed = try await clock.measure {
                let captured = ItemBuilder.build(from: snapshot, source: SourceApp(bundleID: "a", name: "A"), maxItemBytes: 10_000_000)
                try await env.store.insert(captured)
            }
            samples.append(milliseconds(elapsed))
        }
        assertBudget("capture, 5 MB image", samples: samples, budget: 150)
    }

    /// Hotkey to shelf fully laid out and drawn, with 1,000 items in history, under 80 ms.
    /// Set SHELF_UI_TESTS=1 to put the panel on screen (CI does); otherwise it is drawn offscreen.
    @MainActor
    func testShelfOpen() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        try await env.store.open()
        for index in 0..<1_000 {
            var captured = Make.text("History item number \(index) with some text to show on the card")
            captured.representations = []
            try await env.store.insert(captured)
        }
        let model = ShelfViewModel(store: env.store, hooks: ShelfHooks(perform: { _, _, _ in }, close: {}))
        await model.start()
        let controller = ShelfPanelController(model: model, preferences: env.preferences)
        let onScreen = ProcessInfo.processInfo.environment["SHELF_UI_TESTS"] == "1"
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<10 {
            let elapsed = clock.measure {
                if onScreen {
                    controller.show()
                } else {
                    model.prepareForShow()
                    controller.panel.setFrame(NSRect(x: 0, y: 0, width: 1_512, height: ShelfPanel.height), display: false)
                }
                controller.panel.contentView?.layoutSubtreeIfNeeded()
                controller.panel.displayIfNeeded()
                controller.panel.contentView?.display()
            }
            samples.append(milliseconds(elapsed))
            controller.hide(animated: false)
            await Task.yield()
        }
        assertBudget("shelf open, 1,000 items", samples: samples, budget: 80)
    }

    static func noisyPNG(width: Int, height: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0), let pixels = rep.bitmapData else { return nil }
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0..<(rep.bytesPerRow * height) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        return rep.representation(using: .png, properties: [:])
    }
}
