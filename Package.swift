// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mockingbird",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Mockingbird", targets: ["Mockingbird"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Mockingbird",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        )
    ]
)
