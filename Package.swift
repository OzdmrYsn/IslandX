// swift-tools-version: 5.9
import PackageDescription

// This package is a lightweight command-line build harness for CI/type-checking.
// Open islo.xcodeproj to build the actual .app bundle with Info.plist and
// Apple Events entitlements.
let package = Package(
    name: "islo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "islo", targets: ["islo"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.10.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "islo",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "islo",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "islo.entitlements"
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
