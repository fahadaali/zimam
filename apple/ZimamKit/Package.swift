// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ZimamKit",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)],
    products: [
        .library(name: "ZimamKit", targets: ["ZimamKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/batoulapps/adhan-swift", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ZimamKit",
            dependencies: [.product(name: "Adhan", package: "adhan-swift")],
            // Swift 6 migration, step 1: every Swift 6 concurrency diagnostic, as warnings, while
            // still in the Swift 5 language mode. Once there are none, switch to .v6 below and
            // remove this line.
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(name: "ZimamKitTests", dependencies: ["ZimamKit"]),
    ],
    swiftLanguageModes: [.v5]
)
