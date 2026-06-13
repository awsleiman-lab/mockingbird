// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KokoroBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KokoroBar", targets: ["KokoroBar"])
    ],
    targets: [
        .executableTarget(name: "KokoroBar")
    ]
)
