// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UndertoneApp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Undertone", targets: ["UndertoneApp"])],
    targets: [
        .executableTarget(name: "UndertoneApp"),
        .testTarget(name: "UndertoneAppTests", dependencies: ["UndertoneApp"])
    ]
)
