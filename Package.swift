// swift-tools-version: 5.9
import PackageDescription

// This package is a lightweight command-line build harness for CI/type-checking.
// Open IslandX.xcodeproj to build the actual .app bundle with Info.plist and
// Apple Events entitlements.
let package = Package(
    name: "IslandX",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "IslandX", targets: ["IslandX"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.10.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "IslandX",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "IslandX",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "IslandX.entitlements"
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
