// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LetItSnow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LetItSnow", targets: ["LetItSnow"])
    ],
    targets: [
        .executableTarget(
            name: "LetItSnow",
            path: "Sources/LetItSnow",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Vision"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .testTarget(
            name: "LetItSnowTests",
            dependencies: ["LetItSnow"],
            path: "Tests/LetItSnowTests"
        )
    ]
)
