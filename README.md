# TokenUse

macOS 屏幕边缘毛玻璃组件，支持 **Codex、MiMo Token Plan、Kimi Code、MiniMax、Antigravity** 五大编程平台的**多账号在线套餐配额 + 官方多端计费分模型对账 + 本地会话 Token 融合统计**。

[![Latest Release](https://img.shields.io/github/v/release/zhangsubo/token-use)](https://github.com/zhangsubo/token-use/releases/latest)
[![Download](https://img.shields.io/github/downloads/zhangsubo/token-use/total)](https://github.com/zhangsubo/token-use/releases/latest)
[![License](https://img.shields.io/github/license/zhangsubo/token-use)](LICENSE)

## 核心功能

- **5 大平台 × 多账号配额 + 官方计费跨端对账**：
  - **OpenAI Codex**：自动读取 `$CODEX_HOME` / `~/.codex`、托管备份目录与 CC Switch 多账号，支持**一键切换系统当前活跃 Codex 账号**（自动安全备份原 `auth.json`），并发拉取 `/wham/usage`（5h / 7d / Code Review 7d 实时配额与 Credits 余额）与 `/wham/usage/daily-token-usage-breakdown`（**近 30 天 Desktop / CLI / Web / VS Code / Code Review 跨端占比 + 分模型每日/30d Credits 明细**），兼容 API Key 组织账单查询，并支持解压扫描 `archived_sessions/*.jsonl.zst`
  - **Xiaomi MiMo Token Plan**：**零配置免登识别 Xiaomi MiMo 桌面端会话**自动换取控制台与桌面会员双票据（智能区分通行证过期与未开通套餐，并保留多账号隔离 WebView 登录），并发拉取月度/计划 Token Plan 额度、账户现金余额、桌面会员周限额，以及 `/api/v1/usage`、`/usage/token-plan/list`、`/usage/detail/list` **套餐内 + 按量计费分模型每日账单与联网搜索次数**（月初自动补查上月明细），合并去重 `mimocode.db` 与桌面端 Orca 数据库
  - **Moonshot Kimi Code**：兼容 OAuth、`sk-kimi-...` API Key、Moonshot 开放平台 `sk-...` Key 与 `kimi-auth` 网页会话多账号，自动扫描 `~/.kimi-code` 与 **Kimi Desktop（`daimon-share`）** 会话（过滤 `usageScope=session` 防双计），同时查询 `/coding/v1/usages`、`/coding/v1/models` 与 Web 多场景 `GetUsages`（5h 并发窗口、7d 周限额、**月度全站共享池 vs Coding 池跨场景差额**及已授权模型清单）
  - **MiniMax Token Plan / Coding Plan**：自动记忆国内（`minimaxi.com`）与国际版（`minimax.io`）可用站点，级联查询 `/v1/token_plan/remains`、Coding Plan **全量模型池（通用文本 / 语音 / 视频 / 图像 / 音乐）**、账户可用现金余额与 `/account/amount` **官方分模型计费 Token / 调用次数 / 扣费金额账单**，原生解析 MiniMax Code (`mcode`) `~/.minimax/v2/sessions` 与跨客户端日志
  - **Google Antigravity**：智能分级探测本机 `App / CLI / IDE` 实例 + 多份 Google OAuth 凭证刷新，结合 `RetrieveUserQuotaSummary`、`GetUserStatus` 与 CloudCode `fetchAvailableModels` 展示 Gemini / Argon / Claude-GPT **5h + 7d 分组配额池与全量云端模型实时余量**，并解码 `~/.gemini/antigravity*` Protobuf 会话记录
- **跨设备云端计费摘要条 & 可展开分模型明细面板**：
  - 即使其他电脑、远端服务器、Web 端或 API 渠道产生了消耗而本机无日志，也能通过官方计费接口捕获；自动以 `max(本机今日, 官方云端今日)` 对账展示今日 Token（悬停可对照云端与本机今日明细，且不污染按缓存单价折算的本机等效价值）
  - 每个账号卡片内嵌**官方跨端计费摘要条**，点击即可展开**分模型用量与计费面板**，自动归并同一模型并标注 `官方云端`、`云端+本机`、`本机日志` 三类来源徽章
- **右侧毛玻璃环形停靠条（Edge Dock）+ 实时活跃转圈**：
  - 屏幕边缘停靠条实时展示今日总 Token 与 **5 大平台剩余配额环形仪表盘**（Antigravity 圆环精准对齐当前活跃 IDE 的 **Gemini 配额池**），悬停滑出面板、图钉一键常驻
  - **会话运行实时感知**：轻量检测各平台本地活跃 Session，有会话正在生成时对应平台配额圆环切换为**流光旋转彗星环**（主面板同步显示「运行中」标签），会话单轮完成即自动增量刷新本地用量；空闲时零动画开销静止
- **实测 `tok/s` 生成速率统计 & 2 列电池式配额卡片**：
  - 按各平台本地会话精确时间戳计算 `(输出 + 思考 Token) / 实测生成耗时`（自动剔除工具等待耗时），在平台标题栏、多账号卡片与展开明细中展示 **`⚡ tok/s` 平均速率与最近一轮速率**
  - 各账号采用 **2 列紧凑电池式 `剩余 xx%` 进度条**，支持一键展开输入 / 缓存命中率 / 输出 / 推理 Token 明细
- **个性化排序与等效价值开关**：
  - **平台展示顺序自由拖拽**：在设置中按平台拖拽调整展示顺序，主面板、顶部筛选栏、边缘停靠条与多账号管理页全局实时同步
  - **等效 API 折算价值（`≈ $x,xxx.xx`）**：基于 LiteLLM 分级定价折算等效 API 价值并附悬停说明，支持在设置中一键隐藏估算金额
- **零侵入单遍极速扫描**：纯只读（`mmap` + 只读 SQLite）直接解析各 CLI / IDE 已落盘本地日志并在内存中实时规范化聚合，不挂代理、不注入 CLI Hook、不额外维护中间队列文件；`dashboard-v3.json` 结果快照秒开不置零
- **Sparkle 2.x 自动更新**：EdDSA 签名校验，应用内自动检测并升级

## 系统要求

- macOS 14.0+（Apple Silicon）
- 无外部 CLI 依赖（纯原生 Swift 6 读取本地 JSONL / Zstandard `.jsonl.zst` / SQLite / Protobuf 与官方配额及计费接口）

## 安装与运行

### 方式一：从 Release 下载（推荐）

[下载最新版本 v1.2.0 (TokenUse.zip)](https://github.com/zhangsubo/token-use/releases/latest) · [查看所有版本](https://github.com/zhangsubo/token-use/releases)

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
MARKETING_VERSION=1.2.0 BUILD_NUMBER=1 ./build.sh
```

## 项目结构

```
token-use/
├── Package.swift                              # SPM 包配置 (Swift 6, macOS 14+)
├── build.sh                                   # 打包 .app bundle 与 Sparkle 嵌入脚本
└── Sources/TokenUse/
    ├── AppDelegate.swift                      # 应用入口，LSUIElement + Settings 场景 + Sparkle 初始化
    ├── AppState.swift                         # 全局状态编排，快照秒开 + 云端计费与本机分模型融合对账
    ├── EdgeWindowManager.swift                # 边缘环形仪表盘停靠条（活跃会话流光转圈）与 KeyablePanel
    ├── DebugLogger.swift                      # 按需调试日志（~/Library/Logs/TokenUse/）
    ├── Models/
    │   ├── ProviderModels.swift               # 5 大平台品牌图标、tok/s 速率、云端计费与分模型快照模型
    │   └── TokenData.swift                    # Token 聚合报表与货币/数字格式化工具
    ├── Services/
    │   ├── AccountDiscoveryService.swift      # 本机多客户端/桌面端凭证自动发现与去重
    │   ├── CodexAccountSwitchService.swift    # Codex ~/.codex/auth.json 安全备份与原子切换
    │   ├── MimoSessionMinter.swift            # 小米 MiMo 桌面端 SSO 免登换票服务
    │   ├── NativeUsageService.swift           # 单遍字节级极速本地扫描与实测 tok/s 速率提取
    │   ├── ProviderQuotaService.swift         # 5 大平台在线配额、官方计费分模型明细与 OAuth 续期
    │   └── SessionActivityMonitor.swift       # 5 大平台本地活跃会话实时状态监测器
    ├── Settings/
    │   └── SettingsManager.swift              # 多账号配置、平台拖拽排序与偏好持久化
    ├── Utilities/
    │   ├── KeychainStore.swift                # macOS Keychain 凭证安全存取
    │   ├── ReportManager.swift                # 汇总结果快照原子读写与自动清理（保留最近 5 份）
    │   └── ZstdDecompressor.swift             # 零链接依赖 libzstd / CLI 流式解压工具
    ├── Views/
    │   ├── ContentView.swift                  # 5 大平台 × 多账号电池配额卡片、跨端计费条与分模型面板
    │   ├── SettingsView.swift                 # 多账号管理 + 平台拖拽排序 + 常规与更新设置页
    │   ├── XiaomiConsoleLoginSheet.swift      # 隔离会话的小米控制台 WebView 登录器
    │   ├── DonutChartView.swift               # Swift Charts 圆环图组件
    │   └── StatsPanelView.swift               # 指标统计卡片组件
    └── Resources/
        ├── AppIcon.icns                       # 应用图标
        ├── provider-*.png                     # 5 大平台品牌图标资源
        └── working-mascot.png                 # 默认吉祥物图片
```

## 支持的数据源（本地日志 + 在线配额 & 官方计费）

| 平台 | 本地日志源（只读扫描 + `tok/s` 速率 + 活跃监测） | 在线配额 & 官方跨端分模型计费能力 |
|------|-----------|-------------|
| **Codex** | `$CODEX_HOME/{sessions,archived_sessions}/**/*.jsonl(.zst)` + 自定义目录 | Wham Usage + `daily-token-usage-breakdown`（5h / 7d / Code Review 7d + 跨端占比 + 分模型 Credits + 一键切号） |
| **MiMo Token Plan** | `~/.local/share/mimocode/mimocode.db` + 桌面端 Orca `mimocode.db` 去重 | 桌面端免登 SSO 换票 + `/tokenPlan/usage` + `/usage/token-plan/list` & `/usage/detail/list` 分模型账单 + 余额与周限额 |
| **Kimi Code** | `~/.kimi-code`、`~/.kimi`、Kimi Desktop `daimon-share/**/wire.jsonl` | `/coding/v1/usages` + `/coding/v1/models` + Web 多场景 `GetUsages`（5h + 7d + 月度全站/Coding 池差额 + 授权模型） |
| **MiniMax** | `~/.minimax/v2/sessions` (`mcode`)、`opencode.db`、`~/.claude/projects` | `/v1/token_plan/remains` + 全模型池 `/coding_plan/remains` + `/account/amount` 官方分模型账单与现金余额（CN & Global） |
| **Antigravity** | `~/.gemini/antigravity*/conversations/*.db`（Protobuf）+ `transcript.jsonl` | `RetrieveUserQuotaSummary` + `GetUserStatus` + CloudCode `fetchAvailableModels`（5h/7d 配额池 + 全量云端模型实时余量） |

## 隐私与安全说明

- 所有手动配置的 API Key、OAuth Token 与会话 Cookie 均仅保存在本机 **macOS Keychain**（`com.tokenuse.app.accounts`）中。
- 本地会话扫描完全在离线本机以**只读方式**完成，不修改任何 CLI 原生日志，在线配额与计费请求仅直连各平台官方 API，无任何第三方遥测或中转服务。

## 致谢

- 模型定价数据参考 [junhoyeo/tokscale](https://github.com/junhoyeo/tokscale)
- 部分多平台配额协议与桌面端发现能力参考 [Javis603/token-monitor](https://github.com/Javis603/token-monitor)（MIT）

## 发布流程

```bash
git tag v1.2.0
git push origin main --tags
```

GitHub Actions 自动构建 `TokenUse.app`、嵌入 `BUILD_NUMBER`、执行 EdDSA 签名、发布 GitHub Release，并同步更新 `gh-pages` 分支上的 `appcast.xml`（同时写入 `<sparkle:version>` 与 `<sparkle:shortVersionString>`）。
