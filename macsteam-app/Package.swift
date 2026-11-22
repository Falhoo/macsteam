// swift-tools-version: 6.2
import Foundation
import PackageDescription

var targets: [Target] = [
    .executableTarget(
        name: "MacsteamApp",
        dependencies: [
            "Sparkle",
            // NotProton, built from ../notproton/app (see build.sh).
            .product(name: "NotProtonApp", package: "app"),
            // OnlineFix Manager's pages, built from ../onlinefix (see build.sh).
            .product(name: "OnlineFixApp", package: "onlinefix"),
            // CloudRedirect's macOS UI, built from ../vendor/cloudredirect/ui-macos/swift-app.
            .product(name: "CloudRedirectUI", package: "swift-app"),
            // Its installer/config support, from ../vendor/cloudredirect/ui-macos.
            .product(name: "CloudRedirectSupport", package: "ui-macos"),
            // Liquid Glass components shared with NotProton's and OnlineFix's pages.
            .product(name: "GlassUI", package: "glass-ui"),
        ],
        path: "Sources/MacsteamApp",
        resources: [.copy("Resources/hubcap-store.js")]
    )
]

if FileManager.default.fileExists(atPath: "Tests/MacsteamAppTests") {
    targets.append(.testTarget(
        name: "MacsteamAppTests",
        dependencies: ["MacsteamApp"],
        path: "Tests/MacsteamAppTests"
    ))
}

let package = Package(
    name: "MacsteamApp",
    platforms: [
        .macOS(.v26)   // the Liquid Glass UI needs macOS 26
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(path: "../notproton/app"),
        .package(path: "../onlinefix"),
        .package(path: "../vendor/cloudredirect/ui-macos/swift-app"),
        .package(path: "../vendor/cloudredirect/ui-macos"),
        .package(path: "../glass-ui"),
    ],
    targets: targets
)
