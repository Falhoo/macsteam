// swift-tools-version: 6.2
import PackageDescription

// OnlineFix Manager's pages, built as a library that macSteam's config app hosts
// (see onlinefix/Sources/OnlineFixApp/Embed.swift and macsteam-app/Package.swift).
let package = Package(
    name: "OnlineFixApp",
    platforms: [.macOS(.v26)],   // Liquid Glass pages need macOS 26
    products: [
        .library(name: "OnlineFixApp", targets: ["OnlineFixApp"]),
    ],
    dependencies: [
        // Shared Liquid Glass components (../glass-ui in the macSteam tree).
        .package(path: "../glass-ui"),
    ],
    targets: [
        .target(
            name: "OnlineFixApp",
            dependencies: [.product(name: "GlassUI", package: "glass-ui")],
            path: "Sources/OnlineFixApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OnlineFixAppTests",
            dependencies: ["OnlineFixApp"],
            path: "Tests/OnlineFixAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
