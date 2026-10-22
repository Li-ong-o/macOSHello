// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FaceUnlockTool",
    targets: [
        .executableTarget(
            name: "FaceUnlockTool",
            path: "Sources/FaceUnlockTool",
            swiftSettings: [.unsafeFlags(["-target", "arm64-apple-macos14.0"])]
        )
    ]
)
