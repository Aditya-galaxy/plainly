// swift-tools-version: 6.0
import PackageDescription

// The rules Plainly runs on every platform (web: src/lib, Android: Core.kt), ported line for line to Swift.
let package = Package(
    name: "PlainlyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PlainlyCore", targets: ["PlainlyCore"])],
    targets: [
        .target(name: "PlainlyCore"),
        .testTarget(name: "PlainlyCoreTests", dependencies: ["PlainlyCore"], resources: [.copy("Fixtures")]),
    ]
)
