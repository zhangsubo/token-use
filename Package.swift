// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenUse",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenUse", targets: ["TokenUse"])
    ],
    dependencies: [
        // Sparkle 2.x: 应用内自动更新框架
        // - 启动后由 SPUStandardUpdaterController 自动按 SUFeedURL 拉取 appcast
        // - 走 EdDSA 验签 + bundle-level codesign
        // - 替换路径由 Bundle.main.bundleURL 自定位
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        // SQLite.swift: 纯 Swift 的 SQLite 包装库，用于读取 OpenCode 数据库
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0")
    ],
    targets: [
        .executableTarget(
            name: "TokenUse",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            // Info.plist 与 Localization 模板由 build.sh 写入 .app/Contents 与 Sparkle.framework，
            // 不应被 SwiftPM 当作普通 resource 打包到子 bundle 里
            exclude: ["Info.plist", "Localization"],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
