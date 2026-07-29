# TokenUse

macOS 菜单栏应用，可视化展示本地 AI 工具的 Token 使用量统计。

[![Latest Release](https://img.shields.io/github/v/release/zhangsubo/token-use)](https://github.com/zhangsubo/token-use/releases/latest)
[![Download](https://img.shields.io/github/downloads/zhangsubo/token-use/total)](https://github.com/zhangsubo/token-use/releases/latest)
[![License](https://img.shields.io/github/license/zhangsubo/token-use)](LICENSE)

**[📦 下载最新版本 (v0.3.0)](https://github.com/zhangsubo/token-use/releases/download/v0.3.0/TokenUse.zip)**

## 功能

- **边缘触发面板**：屏幕右侧边缘悬停触发，滑出半透明毛玻璃面板，鼠标离开自动收起
- **原生日志扫描**：直接读取本地日志，支持 Claude、Codex、Kimi、Mimo、OpenCode 等 26+ 客户端
- **智能缓存**：1 小时缓存策略，首次启动约 8 秒，后续启动 <1 秒即时加载
- **圆环图展示**：左侧显示前 5 大模型 + Others 的 Token 使用占比
- **详细统计**：右侧显示全量总量（近 90 天）、预计价格、今日使用量、今日金额及更新时间
- **毛玻璃视觉效果**：多层渐变叠加 + 半透明模糊，遵循 macOS HIG 设计规范
- **自动更新**：通过 Sparkle 2.x 实现应用内自动更新

## 系统要求

- macOS 14.0+
- 无外部依赖（直接读取本地日志文件和 SQLite 数据库）

## 安装与运行

### 方式一：从 Release 下载（推荐）

**[📦 下载 v0.3.0](https://github.com/zhangsubo/token-use/releases/download/v0.3.0/TokenUse.zip)** | [查看所有版本](https://github.com/zhangsubo/token-use/releases)

1. 下载 `TokenUse.zip` 并解压得到 `TokenUse.app`
2. 将 `TokenUse.app` 移动到 `~/Applications/` 或 `/Applications/`
3. 首次打开需要绕过 macOS Gatekeeper：
   - 双击 `TokenUse.app` → 系统提示"无法打开"
   - 右键 `TokenUse.app` → 打开 → 再次点"打开"确认
   - 此后可直接双击运行

**自动更新**：应用会通过 [Sparkle](https://sparkle-project.org) 自动检查更新（每 24 小时一次），或在设置中手动触发。新版本会自动下载、验证签名并安装。

### 方式二：本地构建

```bash
git clone https://github.com/zhangsubo/token-use.git
cd token-use
./build.sh
cp -R TokenUse.app ~/Applications/
open ~/Applications/TokenUse.app
```

### 方式三：开发调试

```bash
swift run
```

### 环境变量

`build.sh` 接收两个 env 用于版本注入（CI 自动设）：

```bash
MARKETING_VERSION=0.2.0 BUILD_NUMBER=42 ./build.sh
```

## 项目结构

```
token-use/
├── Package.swift                     # SPM 包配置 (Swift 6, macOS 14+)
├── build.sh                          # 打包 .app bundle 脚本
├── Sources/TokenUse/
│   ├── AppDelegate.swift             # 应用入口，LSUIElement 模式
│   ├── AppState.swift                # 全局状态管理，智能缓存 + 并发数据获取
│   ├── EdgeWindowManager.swift       # 屏幕边缘触发面板 + 鼠标监控
│   ├── DebugLogger.swift             # 调试日志工具
│   ├── Models/
│   │   └── TokenData.swift           # TokscaleReport / TokenStats 数据模型
│   ├── Views/
│   │   ├── ContentView.swift         # 主视图 + TokenDashboardContent
│   │   ├── DonutChartView.swift      # Swift Charts 圆环图
│   │   ├── StatsPanelView.swift      # MetricCard 统计卡片
│   │   └── SettingsView.swift        # 设置面板
│   ├── Services/
│   │   ├── NativeUsageService.swift  # 原生日志扫描服务 (actor)
│   │   └── TokscaleService.swift     # 已废弃（保留兼容）
│   ├── Settings/
│   │   └── SettingsManager.swift     # 用户设置管理
│   ├── Utilities/
│   │   └── ReportManager.swift       # 报告文件缓存管理 (actor)
│   └── Resources/
│       ├── AppIcon.icns              # 应用图标
│       └── working-mascot.png        # 吉祥物图片
└── CLAUDE.md                         # Claude Code 项目指引
```

## 技术栈

- **Swift 6 + SwiftUI**：现代并发模型（actor、async/await、@MainActor）
- **Swift Charts**：原生圆环图渲染
- **AppKit**：NSPanel 边缘触发、NSEvent 全局鼠标监控
- **SQLite.swift**：OpenCode 数据库读取
- **Sparkle 2.x**：应用内自动更新（EdDSA 签名验证）
- **GitHub Actions**：自动化发布流程（构建、签名、appcast 生成）

## 支持的数据源

| 客户端 | 路径 | 格式 | Token 字段 |
|--------|------|------|-----------|
| Claude Code | `~/.claude/projects/**/*.jsonl` | JSONL | `message.usage.*` |
| Codex | `~/.codex/sessions/**/*.jsonl` | JSONL | `payload.info.*_token_usage` |
| Kimi | `~/.kimi/sessions/**/wire.jsonl` | JSONL | `message.payload.token_usage` |
| Mimo | `~/.mimo/sessions/**/*.jsonl` | JSONL | `message.usage.*` |
| OpenCode | `~/.local/share/opencode/*.db` | SQLite | `session` 表 |

## 发布流程

```bash
git tag v0.2.0
git push --tags
```

CI 自动：build → ad-hoc 签 → zip → EdDSA 签 → GitHub Release → 推送 `gh-pages` 分支托管 appcast。用户启动 app 后 Sparkle 自动检测并提示升级。
