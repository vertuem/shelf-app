// swift-tools-version:6.2
import PackageDescription

// Two third-party dependencies, both MIT, pinned to an exact tag. Keep it that
// way: Shelf sees everything you copy, so every dependency is a liability.
let package = Package(
    name: "Shelf",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Shelf", targets: ["Shelf"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"),
    ],
    targets: [
        .target(
            name: "ShelfCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "ShelfCapture",
            dependencies: ["ShelfCore"]
        ),
        .target(
            name: "ShelfPaste",
            dependencies: ["ShelfCore"]
        ),
        .target(
            name: "ShelfUI",
            dependencies: [
                "ShelfCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .executableTarget(
            name: "Shelf",
            dependencies: ["ShelfCore", "ShelfCapture", "ShelfPaste", "ShelfUI"]
        ),
        .testTarget(
            name: "ShelfTests",
            dependencies: ["ShelfCore", "ShelfCapture", "ShelfPaste", "ShelfUI", "Shelf"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
