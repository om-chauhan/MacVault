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
        path: "Sources/MacVaultApp",
        // Dock icon for the unbundled run (`swift run`, the MacVaultApp scheme); the bundled app
        // uses the asset catalog instead.
        resources: [.copy("Resources/AppIcon.png")]
    )
)
#endif

let package = Package(
    name: "MacVault",
    // iOS is listed only so Xcode can type-check MacVaultCore when an iOS destination is selected
    // (Duration and Clock need iOS 16). The app product is macOS-only; run the MacVaultApp scheme
    // against "My Mac".
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: products,
    targets: targets
)
