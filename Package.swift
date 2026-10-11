// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Bubble",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-update (EdDSA-signed appcast). See README "Updates".
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Bubble",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Bubble",
            linkerSettings: [
                // scripts/bundle.sh embeds Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "BubbleTests",
            dependencies: ["Bubble"],
            path: "Tests/BubbleTests"
        ),
    ]
)
