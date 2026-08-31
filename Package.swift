// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bnkscope-field",
    platforms: [.iOS("27.0"), .macOS("14.0")],
    products: [
        .library(name: "BNKKit", targets: ["BNKKit"]),
        .executable(name: "bnkfield", targets: ["bnkfield"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "BNKKit", dependencies: ["Yams"]),
        .executableTarget(name: "bnkfield", dependencies: ["BNKKit"]),
        .testTarget(name: "BNKKitTests", dependencies: ["BNKKit"], resources: [.copy("Fixtures")]),
    ]
)
