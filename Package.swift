// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenUse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenUse", targets: ["TokenUse"])
    ],
    targets: [
        .executableTarget(
            name: "TokenUse",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
