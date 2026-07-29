# TokenUse 开发文档

## 快速开始

### 环境要求

- macOS 14.0+
- Xcode 15.0+ (Swift 6)
- 可选：已安装支持的 AI 客户端（Claude、Codex、Kimi、Mimo、OpenCode）以生成本地日志

### 本地开发

```bash
# 克隆仓库
git clone https://github.com/zhangsubo/token-use.git
cd token-use

# Debug 模式运行（会输出详细日志到控制台和 ~/Applications/token-use/debug.log）
swift run

# Release 构建
./build.sh

# 打开构建的 app
open TokenUse.app
```

### 调试日志

`DebugLogger.enabled` 默认为 `true`，调试日志会同时输出到：
- 控制台（`swift run` 时可见）
- `~/Applications/token-use/debug.log`

生产环境发布前，可在 `DebugLogger.swift` 中设置 `enabled = false`。

## 架构概览

### 核心组件

```
AppDelegate (entry point)
    ↓
EdgeWindowManager.setup() → 创建触发区和面板窗口
    ↓
AppState.start() → 智能缓存加载 + 数据获取
    ↓
NativeUsageService → 扫描本地日志
    ↓
ReportManager → 缓存管理（1小时有效期）
    ↓
TokenDashboardContent → UI 渲染
```

### 并发模型

- **@MainActor**: `AppState`、`AppDelegate`、`EdgeWindowManager`、`SettingsManager`
- **actor**: `NativeUsageService`、`ReportManager`
- **Sendable**: 所有数据模型（`TokscaleReport`、`TokenStats` 等）

### 数据流

1. **冷启动**（无缓存）：
   - 调用 `NativeUsageService.fetchAllTime()` (90天范围)
   - 调用 `NativeUsageService.fetchToday()`
   - 保存全量报告到 `~/Applications/token-use/report/`
   - 耗时约 8 秒

2. **热启动**（缓存有效）：
   - 从 `ReportManager.loadLatestReport()` 加载缓存
   - 立即显示界面（<1秒）
   - 后台异步更新今日数据

3. **定时刷新**：
   - 默认 30 分钟（可在设置中调整）
   - 使用 `Timer.scheduledTimer` 触发 `AppState.fetchData()`

## 数据源扫描逻辑

### Claude Code

- 路径：`~/.claude/projects/**/*.jsonl`
- 过滤：文件修改时间 >= 查询区间起点 -1 天
- 解析：`type == "assistant"` 的行，提取 `message.usage.*`

### Codex

- 路径：`~/.codex/sessions/YYYY/MM/DD/*.jsonl`
- 解析：`type == "event_msg"` + `payload.type == "token_count"`
- Token 字段：`payload.info.last_token_usage` 或 `total_token_usage`

### Kimi

- 路径：`~/.kimi/sessions/**/wire.jsonl`
- 解析：`message.type == "StatusUpdate"` + `payload.token_usage`

### Mimo

- 路径：`~/.mimo/sessions/**/*.jsonl`
- 逻辑与 Claude 类似，支持 `cache_read_input_tokens` / `cache_creation_input_tokens`

### OpenCode

- 路径：`~/.local/share/opencode/opencode.db` 或 `opencode-*.db`
- 使用 **SQLite.swift** 直接查询 `session` 表
- 查询条件：`time_updated >= startMillis AND time_updated < endMillis`
- 字段：`tokens_input`, `tokens_output`, `tokens_cache_read`, `tokens_cache_write`, `tokens_reasoning`, `cost`

## 定价计算

`PriceResolver` 内置 20+ 模型的价格（单位：$/M tokens）：

| 模型系列 | Input | Output | Cache Read | Cache Write |
|---------|-------|--------|------------|-------------|
| GPT-5.5 | 1.5 | 12.0 | 0.15 | 1.5 |
| Claude Opus 5 | 15.0 | 75.0 | 1.5 | 18.75 |
| Claude Sonnet 4 | 3.0 | 15.0 | 0.3 | 3.75 |
| Kimi K2.7 | 1.0 | 4.0 | 0.2 | 1.0 |
| Mimo v2.5 Pro | 0.8 | 3.0 | 0.16 | 0.8 |
| DeepSeek v4 | 0.27 | 1.1 | 0.07 | 0.27 |

支持自动识别模型名称（大小写不敏感，含 `gpt-5.5`、`opus-5`、`kimi-k2.7` 等关键词）。

## 视觉设计

### 颜色系统

```swift
// 图表颜色（按使用量排序）
chartBlue    // 第1位
chartGreen   // 第2位
chartOrange  // 第3位
chartPurple  // 第4位
chartPink    // 第5位
chartGray    // Others
```

### 毛玻璃效果

- **背景材质**: `.hudWindow`
- **混合模式**: `.behindWindow`
- **圆角**: 28pt (continuous)
- **多层渐变**: 3层（基础渐变 + 高光渐变 + 边框渐变）
- **阴影**: 多层叠加（主阴影 + 辉光阴影）

### 边缘触发器

- **位置**: 屏幕右侧（可配置 left/right/top/bottom）
- **尺寸**: 43pt × 157pt
- **悬停效果**: 颜色加深 + 辉光增强 + 阴影扩大
- **动画**: 0.25s easeOut（显示），0.2s easeIn（隐藏）

## 发布流程

### 本地测试

```bash
# 设置版本号
MARKETING_VERSION=0.3.0 BUILD_NUMBER=1 ./build.sh

# 验证 Info.plist
plutil -p TokenUse.app/Contents/Info.plist | grep -E 'Version|Build'

# 测试启动
open TokenUse.app
```

### CI 发布

1. 在 GitHub 仓库设置中添加 Secret：
   - `SPARKLE_PRIVATE_KEY`：运行 `./bin/generate_keys` 生成，取 `dsa_private.pem` 的 base64

2. 推送 tag 触发发布：
   ```bash
   git tag v0.3.0
   git push origin v0.3.0
   ```

3. GitHub Actions 自动执行：
   - 构建 arm64 release
   - Ad-hoc 签名（无需 Apple Developer 账号）
   - 打包 `TokenUse.zip`
   - 使用 Sparkle 的 `sign_update` 生成 EdDSA 签名
   - 创建 GitHub Release
   - 更新 `appcast.xml` 并推送到 `gh-pages` 分支

4. 用户侧更新：
   - 启动 app 后，Sparkle 自动检查 `https://zhangsubo.github.io/token-use/appcast.xml`
   - 发现新版本后弹窗提示
   - 用户确认后自动下载、验证签名、安装

### appcast.xml 格式

```xml
<item>
  <title>Version 0.3.0</title>
  <sparkle:version>0.3.0</sparkle:version>
  <sparkle:shortVersionString>0.3.0</sparkle:shortVersionString>
  <pubDate>Tue, 29 Jul 2026 10:00:00 +0800</pubDate>
  <enclosure 
    url="https://github.com/zhangsubo/token-use/releases/download/v0.3.0/TokenUse.zip"
    sparkle:edSignature="..."
    length="1234567"
    type="application/octet-stream" />
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
</item>
```

## 常见问题

### Q: 为什么 All Time 只显示 90 天？

A: OpenCode 数据库可能很大（几十万行），全量查询会导致启动超时。90 天是性能和完整性的平衡点。

### Q: 如何添加新的数据源？

A: 在 `NativeUsageService` 中添加新的 `scan*` 方法：

```swift
private func scanNewClient(interval: DateInterval, into accumulator: inout UsageAccumulator) {
    let root = homeDirectory.appendingPathComponent(".newclient/logs")
    for file in jsonlFiles(under: root) {
        for object in jsonObjects(in: file) {
            // 解析逻辑...
            accumulator.add(
                client: "newclient",
                provider: "provider-name",
                model: modelName,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning,
                messageCount: 1,
                cost: PriceResolver.estimate(...)
            )
        }
    }
}
```

然后在 `fetch(interval:)` 中调用：

```swift
private func fetch(interval: DateInterval) async throws -> TokscaleReport {
    var accumulator = UsageAccumulator()
    scanCodex(interval: interval, into: &accumulator)
    scanClaude(interval: interval, into: &accumulator)
    scanNewClient(interval: interval, into: &accumulator)  // 新增
    // ...
}
```

### Q: 如何修改缓存有效期？

A: 在 `ReportManager` 中修改 `cacheValidityDuration`：

```swift
private let cacheValidityDuration: TimeInterval = 7200  // 2 小时
```

### Q: 如何禁用调试日志？

A: 在 `DebugLogger.swift` 中设置：

```swift
static let enabled = false
```

## 依赖管理

- **SQLite.swift**: 用于 OpenCode 数据库查询（SPM 依赖）
- **Sparkle**: 自动更新框架（SPM 依赖）

查看 `Package.swift` 了解完整依赖列表。

## 参考资源

- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [Sparkle Documentation](https://sparkle-project.org/documentation/)
- [macOS Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/macos)
- [SQLite.swift](https://github.com/stephencelis/SQLite.swift)
