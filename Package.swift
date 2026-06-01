// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenUse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenUse", targets: ["TokenUse"])
    ],
    dependencies: [
        // Sparkle 2.x: 应用内自动更新框架
        // - 启动后由 SPUStandardUpdaterController 自动按 SUFeedURL 拉取 appcast
        // - 走 EdDSA 验签 + bundle-level codesign
        // - 替换路径由 Bundle.main.bundleURL 自定位
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "TokenUse",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            // Info.plist 模板由 build.sh 读取后写入 .app/Contents/Info.plist，
            // 不应被 SwiftPM 当作 resource bundle 到产物里
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
