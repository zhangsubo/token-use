# TokenUse

macOS 屏幕边缘毛玻璃组件，支持 **Codex、MiMo Token Plan、Kimi Code、MiniMax、Antigravity** 五大编程平台的**多账号在线套餐配额 + 本地会话 Token 双轨统计**。

[![Latest Release](https://img.shields.io/github/v/release/zhangsubo/token-use)](https://github.com/zhangsubo/token-use/releases/latest)
[![Download](https://img.shields.io/github/downloads/zhangsubo/token-use/total)](https://github.com/zhangsubo/token-use/releases/latest)
[![License](https://img.shields.io/github/license/zhangsubo/token-use)](LICENSE)

## 核心功能

- **5 大平台 × 多账号双轨统计**：
  - **OpenAI Codex**：自动读取 `$CODEX_HOME` / `~/.codex`、托管备份目录与 CC Switch 多账号，支持**一键切换系统当前活跃 Codex 账号**（自动安全备份原 `auth.json`），拉取 5h / 7d / Code Review 7d 实时配额与 Credits 余额，并支持解压扫描 `archived_sessions/*.jsonl.zst`
  - **Xiaomi MiMo Token Plan**：**零配置免登识别 Xiaomi MiMo 桌面端会话**自动换取控制台与桌面会员双票据（同时保留多账号隔离 WebView 登录），并发拉取月度/计划 Token Plan 额度、账户现金余额与桌面会员周限额，合并去重 `mimocode.db` 与桌面端 Orca 数据库
  - **Moonshot Kimi Code**：兼容 OAuth、`sk-kimi-...` API Key 与 `kimi-auth` 网页会话多账号，自动扫描 `~/.kimi-code` 与 **Kimi Desktop（`daimon-share`）** 会话（过滤 `usageScope=session` 防双计），同时展示 5h 并发窗口、7d 周限额与月度共享池
  - **MiniMax Token Plan / Coding Plan**：自动记忆国内（`minimaxi.com`）与国际版（`minimax.io`）可用站点，级联查询 `/v1/token_plan/remains`、Coding Plan 与账户可用现金余额，原生解析 MiniMax Code (`mcode`) `~/.minimax/v2/sessions` 与跨客户端日志
  - **Google Antigravity**：智能分级探测本机 `App / CLI / IDE` 实例 + 多份 Google OAuth 凭证刷新，优先调用 `RetrieveUserQuotaSummary` 展示 Gemini / Argon / Claude-GPT **5h + 7d 分组配额池**，并解码 `~/.gemini/antigravity*` Protobuf 会话记录
- **右侧毛玻璃环形停靠条（Edge Dock）+ 2 列电池式配额卡片**：
  - 屏幕右缘停靠条实时展示今日总 Token 与 **5 大平台剩余配额环形仪表盘**，悬停滑出面板、图钉一键常驻
  - 各账号采用 **2 列紧凑电池式 `剩余 xx%` 进度条**，支持一键展开输入 / 缓存命中率 / 输出 / 推理 Token 明细
- **单遍极速扫描与无闪烁刷新**：单遍并发同时产出今日（Today）与近 90 天（90d）用量、缓存命中率及 LiteLLM 分级定价估算；`dashboard-v3.json` 快照秒开不置零，手动/定时刷新始终实时同步
- **Sparkle 2.x 自动更新**：EdDSA 签名校验，应用内自动检测并升级

## 系统要求

- macOS 14.0+（Apple Silicon）
- 无外部 CLI 依赖（纯原生 Swift 6 读取本地 JSONL / Zstandard `.jsonl.zst` / SQLite / Protobuf 与官方配额接口）

## 安装与运行

### 方式一：从 Release 下载（推荐）

[下载最新版本 v1.0.0 (TokenUse.zip)](https://github.com/zhangsubo/token-use/releases/latest) · [查看所有版本](https://github.com/zhangsubo/token-use/releases)

1. 下载 `TokenUse.zip` 并解压得到 `TokenUse.app`
2. 将 `TokenUse.app` 移动到 `~/Applications/` 或 `/Applications/`
3. 首次打开需要绕过 macOS Gatekeeper（右键 `TokenUse.app` → 打开 → 确认），并在「系统设置 → 隐私与安全性 → 辅助功能」中授权以启用屏幕边缘悬停触发

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
# 开启调试日志（输出至 ~/Library/Logs/TokenUse/debug.log）
TOKENUSE_DEBUG=1 swift run
```

### 环境变量

`build.sh` 支持注入版本号与构建号（CI 自动传入）：

```bash
MARKETING_VERSION=1.0.0 BUILD_NUMBER=1 ./build.sh
```

## 项目结构

```
token-use/
├── Package.swift                              # SPM 包配置 (Swift 6, macOS 14+)
├── build.sh                                   # 打包 .app bundle 与 Sparkle 嵌入脚本
└── Sources/TokenUse/
    ├── AppDelegate.swift                      # 应用入口，LSUIElement + Settings 场景 + Sparkle 初始化
    ├── AppState.swift                         # 全局状态编排，快照秒开 + Codex 切换 + 双轨同步
    ├── EdgeWindowManager.swift                # 右侧环形仪表盘停靠条 (Edge Dock) 与 KeyablePanel
    ├── DebugLogger.swift                      # 按需调试日志（~/Library/Logs/TokenUse/）
    ├── Models/
    │   ├── ProviderModels.swift               # 5 大平台品牌图标、缓存命中明细与配额快照模型
    │   └── TokenData.swift                    # Token 聚合报表与数字格式化工具
    ├── Services/
    │   ├── AccountDiscoveryService.swift      # 本机多客户端/桌面端凭证自动发现与去重
    │   ├── CodexAccountSwitchService.swift    # Codex ~/.codex/auth.json 安全备份与原子切换
    │   ├── MimoSessionMinter.swift            # 小米 MiMo 桌面端 SSO 免登换票服务
    │   ├── NativeUsageService.swift           # 单遍字节级极速本地扫描（JSONL/Zstd/SQLite/Protobuf）
    │   └── ProviderQuotaService.swift         # 5 大平台在线套餐配额查询与 OAuth 续期
    ├── Settings/
    │   └── SettingsManager.swift              # 多账号配置与常规偏好持久化
    ├── Utilities/
    │   ├── KeychainStore.swift                # macOS Keychain 凭证安全存取
    │   ├── ReportManager.swift                # 缓存快照读写与自动清理（保留最近 5 份）
    │   └── ZstdDecompressor.swift             # 零链接依赖 libzstd / CLI 流式解压工具
    ├── Views/
    │   ├── ContentView.swift                  # 5 大平台 × 多账号 2 列电池配额卡片主面板
    │   ├── SettingsView.swift                 # 多账号管理 + 常规与更新双标签设置页（支持独立窗口/弹窗）
    │   ├── XiaomiConsoleLoginSheet.swift      # 隔离会话的小米控制台 WebView 登录器
    │   ├── DonutChartView.swift               # Swift Charts 圆环图组件
    │   └── StatsPanelView.swift               # 指标统计卡片组件
    └── Resources/
        ├── AppIcon.icns                       # 应用图标
        ├── provider-*.png                     # 5 大平台品牌图标资源
        └── working-mascot.png                 # 默认吉祥物图片
```

## 支持的数据源（本地日志 + 在线配额）

| 平台 | 本地日志源 | 在线配额能力 |
|------|-----------|-------------|
| **Codex** | `$CODEX_HOME/{sessions,archived_sessions}/**/*.jsonl(.zst)` + 自定义目录 | ChatGPT Wham Usage API（5h / 7d / Code Review 7d + Credits + 一键切号） |
| **MiMo Token Plan** | `~/.local/share/mimocode/mimocode.db` + 桌面端 Orca `mimocode.db` 去重 | MiMo 桌面端免登 SSO 换票 + 控制台 `/tokenPlan/usage`、余额与会员周限额 |
| **Kimi Code** | `~/.kimi-code`、`~/.kimi`、Kimi Desktop `daimon-share/**/wire.jsonl` | `/coding/v1/usages` + Web `GetUsages`（5h + 7d + 月度共享池） |
| **MiniMax** | `~/.minimax/v2/sessions` (`mcode`)、`opencode.db`、`~/.claude/projects` | `/v1/token_plan/remains` + `/coding_plan/remains` + 现金余额（CN & Global） |
| **Antigravity** | `~/.gemini/antigravity*/conversations/*.db`（Protobuf）+ `transcript.jsonl` | 本机 RPC `RetrieveUserQuotaSummary` + CloudCode 5h/7d 分组配额池 |

## 隐私与安全说明

- 所有手动配置的 API Key、OAuth Token 与会话 Cookie 均仅保存在本机 **macOS Keychain**（`com.tokenuse.app.accounts`）中。
- 本地会话扫描完全在离线本机完成，在线配额请求仅直连各平台官方 API，无任何第三方遥测或中转服务。

## 致谢

- 模型定价数据参考 [junhoyeo/tokscale](https://github.com/junhoyeo/tokscale)
- 部分多平台配额协议与桌面端发现能力参考 [Javis603/token-monitor](https://github.com/Javis603/token-monitor)（MIT）

## 发布流程

```bash
git tag v1.0.0
git push origin main --tags
```

GitHub Actions 自动构建 `TokenUse.app`、嵌入 `BUILD_NUMBER`、执行 EdDSA 签名、发布 GitHub Release，并同步更新 `gh-pages` 分支上的 `appcast.xml`（同时写入 `<sparkle:version>` 与 `<sparkle:shortVersionString>`）。
