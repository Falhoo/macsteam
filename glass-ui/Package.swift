// swift-tools-version: 6.2
// Liquid Glass building blocks shared by macSteam, NotProton's pages and OnlineFix's pages.
import PackageDescription

let package = Package(
    name: "GlassUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GlassUI", targets: ["GlassUI"]),
    ],
    targets: [
        .target(name: "GlassUI", path: "Sources/GlassUI"),
    ]
)
