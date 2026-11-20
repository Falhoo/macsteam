// swift-tools-version: 6.0
import PackageDescription
// macSteam hosts the UI too, so the views are a library and the standalone app
// is a thin executable over it.
let package = Package(
    name: "CloudRedirectSwift", platforms: [.macOS(.v15)],
    products: [
        .library(name: "CloudRedirectUI", targets: ["CloudRedirectUI"]),
        .executable(name: "CloudRedirectSwift", targets: ["CloudRedirectSwiftApp"]),
    ],
    dependencies: [.package(path: "..")],
    targets: [
        .target(
            name: "CloudRedirectUI",
            dependencies: [.product(name: "CloudRedirectSupport", package: "ui-macos")],
            path: "Sources/CloudRedirectSwift",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CloudRedirectSwiftApp",
            dependencies: ["CloudRedirectUI"],
            path: "Sources/CloudRedirectSwiftApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "NativeBackendTests", dependencies: ["CloudRedirectUI"], path: "Tests"),
    ]
)
