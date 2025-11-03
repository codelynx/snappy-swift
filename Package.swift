// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SnappySwift",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .watchOS(.v8),
        .tvOS(.v15),
    ],
    products: [
        // Main library product
        .library(
            name: "SnappySwift",
            targets: ["SnappySwift"]
        ),
    ],
    dependencies: [
        // No external dependencies for core library
        // Keep it simple and portable
    ],
    targets: [
        // Main library target
        .target(
            name: "SnappySwift",
            dependencies: [],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // Test target
        .testTarget(
            name: "SnappySwiftTests",
            dependencies: ["SnappySwift"],
            resources: [
                .copy("TestData")
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
