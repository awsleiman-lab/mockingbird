// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mockingbird",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Mockingbird", targets: ["Mockingbird"])
    ],
    targets: [
        .executableTarget(name: "Mockingbird")
    ]
)
