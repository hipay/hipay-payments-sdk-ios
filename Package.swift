// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HiPayFullserviceKMP",
    // Required for the HiPayCard localized .strings catalogs (story 5.2);
    // a device locale with no catalog falls back to EN.
    defaultLocalization: "en",
    platforms: [.iOS(.v15)],
    products: [
        // Headless SDK: payment orchestration, no UI.
        .library(name: "HiPayCore", targets: ["HiPayCore"]),
        // Card entry UI layer on top of HiPayCore.
        .library(name: "HiPayCard", targets: ["HiPayCard"]),
    ],
    targets: [
        // KMP binary produced by scripts/build-xcframework.sh (git-ignored).
        .binaryTarget(
            name: "HiPayFullservice",
            path: "HiPayFullservice.xcframework"
        ),
        .target(
            name: "HiPayCore",
            dependencies: ["HiPayFullservice"]
        ),
        .target(
            name: "HiPayCard",
            dependencies: ["HiPayCore"],
            // Card-network brand icons (neutral + Visa/MC/Amex/Maestro/BCMC/CB),
            // loaded via Image(_:bundle: .module).
            resources: [.process("Resources")]
        ),
        // NOTE: the Swift unit tests (Tests/HiPayCardTests) are NOT an SPM test target: SPM
        // package tests run inside Apple's generic xctest host, which has no application
        // identifier, so every Keychain call fails with errSecMissingEntitlement. They are
        // built and run app-hosted by TestHost/TestHost.xcodeproj instead (see its README).
    ]
)
