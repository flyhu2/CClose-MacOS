// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cclose-mac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cclose-mac", targets: ["CCloseMac"])
    ],
    targets: [
        .executableTarget(
            name: "CCloseMac",
            path: "Sources/CCloseMac"
        ),
        .testTarget(name: "CCloseMacTests", dependencies: ["CCloseMac"])
    ]
)
