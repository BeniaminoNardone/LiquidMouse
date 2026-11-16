// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiquidMouse",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LiquidMouse",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "LiquidMouseTests",
            dependencies: ["LiquidMouse"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
