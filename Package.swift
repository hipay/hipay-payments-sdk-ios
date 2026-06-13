// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HiPayFullserviceKMP",
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
    ]
)
