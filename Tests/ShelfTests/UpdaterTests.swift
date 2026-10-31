import Foundation
@testable import Shelf
import ShelfCore
import XCTest

@MainActor
final class UpdaterTests: XCTestCase {
    func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, age: TimeInterval = 10 * 86_400, dmg: Bool = true) -> Release {
        Release(
            tagName: tag, name: tag, body: "Notes", prerelease: prerelease, draft: draft,
            publishedAt: Date().addingTimeInterval(-age), htmlURL: URL(string: "https://github.com/vertuem/shelf-app/releases/\(tag)")!,
            assets: dmg ? [Release.Asset(name: "Shelf-\(tag).dmg",
                                         browserDownloadURL: URL(string: "https://github.com/vertuem/shelf-app/releases/download/\(tag)/x.dmg")!,
                                         size: 1)] : []
        )
    }

    let current = SemanticVersion("1.0.0")!

    func testSemanticVersionOrdering() {
        let ordered = ["0.9.0", "1.0.0-beta.1", "1.0.0-beta.2", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.10.0", "2.0"]
            .compactMap(SemanticVersion.init)
        XCTAssertEqual(ordered.count, 8)
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(lower, higher, "\(lower) < \(higher)")
        }
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion("1.2.3+45"))
        XCTAssertNil(SemanticVersion("banana"))
    }

    func testPicksNewestEligibleRelease() {
        let candidate = UpdatePolicy.candidate(
            from: [release("v1.0.1"), release("v1.2.0"), release("v0.9.0"), release("v1.1.0")],
            current: current, includeBetas: false, applyStabilityBuffer: true, skippedVersion: nil
        )
        XCTAssertEqual(candidate?.tagName, "v1.2.0")
    }

    func testBetasOnlyWhenIncluded() {
        let releases = [release("v1.1.0-beta.1", prerelease: true)]
        XCTAssertNil(UpdatePolicy.candidate(from: releases, current: current, includeBetas: false, applyStabilityBuffer: false, skippedVersion: nil))
        XCTAssertNotNil(UpdatePolicy.candidate(from: releases, current: current, includeBetas: true, applyStabilityBuffer: false, skippedVersion: nil))
    }

    func testStabilityBufferWaitsThreeDays() {
        let fresh = [release("v1.1.0", age: 86_400)]
        XCTAssertNil(UpdatePolicy.candidate(from: fresh, current: current, includeBetas: false, applyStabilityBuffer: true, skippedVersion: nil))
        XCTAssertNotNil(UpdatePolicy.candidate(from: fresh, current: current, includeBetas: false, applyStabilityBuffer: false, skippedVersion: nil))
    }

    func testSkipsDraftsSkippedVersionsAndReleasesWithoutDMG() {
        XCTAssertNil(UpdatePolicy.candidate(from: [release("v1.1.0", draft: true)], current: current, includeBetas: false, applyStabilityBuffer: false, skippedVersion: nil))
        XCTAssertNil(UpdatePolicy.candidate(from: [release("v1.1.0")], current: current, includeBetas: false, applyStabilityBuffer: false, skippedVersion: "v1.1.0"))
        XCTAssertNil(UpdatePolicy.candidate(from: [release("v1.1.0", dmg: false)], current: current, includeBetas: false, applyStabilityBuffer: false, skippedVersion: nil))
    }

    func testChecksumLookup() {
        let sums = """
            \(String(repeating: "a", count: 64))  Shelf-1.2.0.dmg
            \(String(repeating: "b", count: 64))  Shelf-1.2.0.zip
            """
        XCTAssertEqual(UpdatePolicy.expectedChecksum(in: sums, for: "Shelf-1.2.0.dmg"), String(repeating: "a", count: 64))
        XCTAssertNil(UpdatePolicy.expectedChecksum(in: sums, for: "Shelf-1.2.dmg"), "no partial matches")
        XCTAssertNil(UpdatePolicy.expectedChecksum(in: "nothing here", for: "Shelf-1.2.0.dmg"))
    }

    func testOnlyGitHubDownloadsAreTrusted() {
        XCTAssertTrue(UpdatePolicy.isTrustedDownloadURL(URL(string: "https://github.com/a/b/releases/download/v1/x.dmg")!))
        XCTAssertTrue(UpdatePolicy.isTrustedDownloadURL(URL(string: "https://objects.githubusercontent.com/x")!))
        XCTAssertFalse(UpdatePolicy.isTrustedDownloadURL(URL(string: "http://github.com/x.dmg")!))
        XCTAssertFalse(UpdatePolicy.isTrustedDownloadURL(URL(string: "https://github.com.evil.example/x.dmg")!))
    }

    func testDecodesGitHubReleaseJSON() throws {
        let json = """
            [{"tag_name":"v1.2.0","name":"1.2.0","body":"- Faster","prerelease":false,"draft":false,
              "published_at":"2026-10-01T10:00:00Z","html_url":"https://github.com/vertuem/shelf-app/releases/tag/v1.2.0",
              "assets":[{"name":"Shelf-1.2.0.dmg","size":123,"browser_download_url":"https://github.com/vertuem/shelf-app/releases/download/v1.2.0/Shelf-1.2.0.dmg"},
                        {"name":"SHA256SUMS.txt","size":10,"browser_download_url":"https://github.com/vertuem/shelf-app/releases/download/v1.2.0/SHA256SUMS.txt"}]}]
            """
        let releases = try Release.decodeList(Data(json.utf8))
        XCTAssertEqual(releases.first?.version, SemanticVersion("1.2.0"))
        XCTAssertEqual(releases.first?.dmg?.name, "Shelf-1.2.0.dmg")
        XCTAssertEqual(releases.first?.checksums?.name, "SHA256SUMS.txt")
    }

    func testUpdateModeFollowsTheSignature() {
        XCTAssertEqual(Updater.mode(bundleIdentifier: "com.vertuem.shelf.dev", teamIdentifier: "ABCDE12345"), .off)
        XCTAssertEqual(Updater.mode(bundleIdentifier: "com.vertuem.shelf.dev", teamIdentifier: nil), .off)
        XCTAssertEqual(Updater.mode(bundleIdentifier: "com.vertuem.shelf", teamIdentifier: nil), .unsigned,
                       "an unsigned release still updates, checked by checksum and its own signature")
        XCTAssertEqual(Updater.mode(bundleIdentifier: "com.vertuem.shelf", teamIdentifier: "ABCDE12345"), .signed)
    }

    func testPreviousBundleIsKeptForOneLaunch() throws {
        let defaults = UserDefaults(suiteName: "cleanup-\(UUID())")!
        let preferences = Preferences(defaults: defaults)
        let previous = FileManager.default.temporaryDirectory.appendingPathComponent("Previous-\(UUID())", isDirectory: true)
        let old = previous.appendingPathComponent("Shelf.app")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: previous) }

        Updater.cleanUpAfterUpdate(arguments: ["Shelf", "--updated-from", old.path], preferences: preferences, previousVersions: previous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "kept during the first launch")
        Updater.cleanUpAfterUpdate(arguments: ["Shelf"], preferences: preferences, previousVersions: previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "removed on the next launch")
    }

    func testOnlyAnAppInPreviousVersionIsEverDeleted() throws {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "cleanup-\(UUID())")!)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("Elsewhere-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let previous = FileManager.default.temporaryDirectory.appendingPathComponent("Previous-\(UUID())", isDirectory: true)

        Updater.cleanUpAfterUpdate(arguments: ["Shelf", "--updated-from", elsewhere.path], preferences: preferences, previousVersions: previous)
        Updater.cleanUpAfterUpdate(arguments: ["Shelf"], preferences: preferences, previousVersions: previous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path), "a path outside Previous Version is left alone")
    }
}
