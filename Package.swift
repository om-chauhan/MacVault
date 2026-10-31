// swift-tools-version:5.10
import PackageDescription

// MacVaultCore (domain, scanner, persistence) builds and tests on macOS and Linux.
// The SwiftUI app target is only added on macOS.
var products: [Product] = [
    .library(name: "MacVaultCore", targets: ["MacVaultCore"]),
]

var targets: [Target] = [
    .systemLibrary(
        name: "CSQLite",
        path: "Sources/CSQLite",
        providers: [.apt(["libsqlite3-dev"])]
    ),
    .target(
        name: "MacVaultCore",
        dependencies: ["CSQLite"],
        path: "Sources/MacVaultCore"
    ),
    .testTarget(
        name: "MacVaultCoreTests",
        dependencies: ["MacVaultCore"],
        path: "Tests/MacVaultCoreTests"
    ),
]

#if os(macOS)
// Named MacVaultApp so it does not clash with the Xcode app target "MacVault" (UI test host resolution).
products.append(.executable(name: "MacVaultApp", targets: ["MacVaultApp"]))
targets.append(
    .executableTarget(
        name: "MacVaultApp",
        dependencies: ["MacVaultCore"],
        path: "Sources/MacVaultApp"
    )
)
#endif

let package = Package(
    name: "MacVault",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
