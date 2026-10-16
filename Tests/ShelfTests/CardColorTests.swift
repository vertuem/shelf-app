import AppKit
import ShelfCore
@testable import ShelfUI
import SwiftUI
import XCTest

/// Card headers take the source app's icon color.
@MainActor
final class CardColorTests: XCTestCase {
    /// A white plate with a colored mark on it, like most app icons.
    func icon(plate: NSColor, mark: NSColor?, markFraction: CGFloat = 0.5) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            plate.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14).fill()
            if let mark {
                mark.setFill()
                let side = 64 * markFraction
                NSBezierPath(ovalIn: NSRect(x: 32 - side / 2, y: 32 - side / 2, width: side, height: side)).fill()
            }
            return true
        }
    }

    func testTheColoredMarkWinsOverAWhitePlate() throws {
        let color = try XCTUnwrap(AppIcons.dominantColor(of: icon(plate: .white, mark: .systemRed)))
        let hue = color.hueComponent
        XCTAssertTrue(hue < 0.05 || hue > 0.95, "red, got hue \(hue)")
        XCTAssertGreaterThan(color.saturationComponent, 0.5)
    }

    func testAGrayIconGetsAGray() throws {
        let color = try XCTUnwrap(AppIcons.dominantColor(of: icon(plate: NSColor(white: 0.15, alpha: 1), mark: NSColor(white: 0.9, alpha: 1))))
        XCTAssertLessThan(color.saturationComponent, 0.1)
        XCTAssertGreaterThanOrEqual(color.brightnessComponent, 0.32, "never so dark that the header disappears")
    }

    func testAnEmptyImageHasNoColor() {
        XCTAssertNil(AppIcons.dominantColor(of: NSImage(size: NSSize(width: 16, height: 16))))
    }

    func item(_ kind: ContentKind, app: String?, colorHex: String? = nil) -> ClipItem {
        ClipItem(id: UUID(), createdAt: Date(), lastUsedAt: Date(), kind: kind, sourceBundleID: app, hash: Data(), byteSize: 0, colorHex: colorHex)
    }

    func testUnknownAppsAndColorCardsKeepTheirOwnColor() {
        let text = item(.text, app: "com.example.not-installed")
        XCTAssertEqual(text.palette(fromApp: true).header, ContentKind.text.headerColor)
        let swatch = item(.color, app: "com.apple.Notes", colorHex: "#FF8800")
        XCTAssertEqual(swatch.palette(fromApp: true).header, Color(hex: "#FF8800"))
    }

    func testTypeColorsWhenTurnedOff() {
        let text = item(.text, app: "com.apple.Notes")
        XCTAssertEqual(text.palette(fromApp: false).header, ContentKind.text.headerColor)
    }
}
