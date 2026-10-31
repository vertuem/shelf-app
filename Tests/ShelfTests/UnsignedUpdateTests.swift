import Foundation
@testable import Shelf
import ShelfCore
import XCTest

/// The checks an unsigned release runs on an update, on real disk images:
/// an ad-hoc signed app built here, packed with `hdiutil`.
final class UnsignedUpdateTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("unsigned-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A DMG holding `Shelf.app` with this bundle id and version, ad-hoc signed;
    /// `tamper` changes a signed file afterwards.
    func makeDMG(bundleID: String = "com.vertuem.shelf", version: String = "0.2.0", tamper: Bool = false) throws -> URL {
        let source = folder.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        let app = source.appendingPathComponent("Shelf.app")
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Shelf"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleExecutable": "Shelf", "CFBundleName": "Shelf",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": "1",
        ]
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        XCTAssertEqual(try Shell.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path]).status, 0)
        if tamper {
            try Data("\n".utf8).write(to: macOS.appendingPathComponent("Shelf"), options: .atomic)
        }
        let dmg = folder.appendingPathComponent("Shelf-\(version)-\(UUID().uuidString).dmg")
        XCTAssertEqual(try Shell.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Shelf", "-srcfolder", source.path,
                                                          "-format", "UDZO", dmg.path]).status, 0)
        return dmg
    }

    func stage(_ dmg: URL, current: String = "0.1.2") throws -> URL {
        try Updater.verifyAndStage(dmgURL: dmg, bundleIdentifier: "com.vertuem.shelf", teamIdentifier: nil,
                                   currentVersion: SemanticVersion(current)!, stagingDirectory: folder)
    }

    func testANewerIntactAppIsStaged() throws {
        let staged = try stage(makeDMG())
        XCTAssertEqual(staged.lastPathComponent, ".Shelf-0.2.0.app")
        XCTAssertEqual(Bundle(url: staged)?.bundleIdentifier, "com.vertuem.shelf")
        XCTAssertEqual(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]).status, 0)
    }

    func testAnotherAppIsRefused() throws {
        XCTAssertThrowsError(try stage(makeDMG(bundleID: "com.example.other")))
    }

    func testAnAppChangedAfterSigningIsRefused() throws {
        XCTAssertThrowsError(try stage(makeDMG(tamper: true)))
    }

    func testAnOlderOrSameVersionIsRefused() throws {
        let dmg = try makeDMG(version: "0.1.2")
        XCTAssertThrowsError(try stage(dmg)) { error in
            guard case .notNewer = error as? Updater.UpdateError else { return XCTFail("expected notNewer, got \(error)") }
        }
    }
}
