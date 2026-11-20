// swift-tools-version: 6.0
import PackageDescription

// OnlineFix Manager's pages, built as a library that macSteam's config app hosts
// (see onlinefix/Sources/OnlineFixApp/Embed.swift and macsteam-app/Package.swift).
let package = Package(
    name: "OnlineFixApp",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "OnlineFixApp", targets: ["OnlineFixApp"]),
    ],
    targets: [
        .target(
            name: "OnlineFixApp",
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
