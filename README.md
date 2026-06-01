# TokenUse

macOS 菜单栏应用，可视化展示 tokscale 的 Token 使用量统计。

https://github.com/zhangsubo/token-use

## 功能

- **边缘触发面板**：屏幕右侧边缘悬停触发，滑出半透明毛玻璃面板，鼠标离开自动收起
- **自动检测安装**：首次启动时检查 tokscale 是否安装，未安装则提示并支持一键自动安装
- **定时数据收集**：每 30 分钟自动执行 `tokscale models --json`，导出到 `~/Applications/token-use/report/`
- **圆环图展示**：左侧显示前 5 大模型 + Others 的 Token 使用占比
- **详细统计**：右侧显示全量总量、预计价格、今日使用量、今日金额及更新时间
- **毛玻璃视觉效果**：多层渐变叠加 + 半透明模糊，遵循 macOS HIG 设计规范

## 系统要求

- macOS 14.0+
- Node.js + npm（用于安装 tokscale）

## 安装与运行

### 方式一：从 Release 下载（推荐）

从 [Releases](https://github.com/zhangsubo/token-use/releases) 下载最新 `TokenUse.zip`，解压得到 `TokenUse.app`。

**首次打开**（macOS Gatekeeper 提示）：

1. 双击 `TokenUse.app` —— 系统提示"无法打开，因为来自身份不明的开发者"
2. 在 Finder 右键 `TokenUse.app` → 打开 → 再次点"打开"确认
3. 此后双击即可直接运行

**自动更新**：app 启动后会通过 [Sparkle](https://sparkle-project.org) 自动检查更新（appcast 在 [gh-pages](https://zhangsubo.github.io/token-use/appcast.xml)），设置页可开关 / 手动触发。

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
├── Package.swift                  # SPM 包配置 (Swift 6, macOS 14+)
├── build.sh                       # 打包 .app bundle 脚本
├── Sources/TokenUse/
│   ├── AppDelegate.swift          # 应用入口，LSUIElement 模式
│   ├── AppState.swift             # 全局状态管理，async let 并发获取数据
│   ├── EdgeWindowManager.swift    # 屏幕边缘触发面板 + 鼠标监控
│   ├── Models/
│   │   └── TokenData.swift        # TokscaleReport / TokenStats 数据模型
│   ├── Views/
│   │   ├── ContentView.swift      # 独立窗口容器
│   │   ├── DonutChartView.swift   # Swift Charts 圆环图
│   │   └── StatsPanelView.swift   # MetricCard 统计卡片
│   ├── Services/
│   │   └── TokscaleService.swift  # tokscale CLI 调用 (actor)
│   ├── Utilities/
│   │   └── ReportManager.swift    # 报告文件缓存管理 (actor)
│   └── Resources/
│       ├── AppIcon.icns           # 应用图标
│       └── working-mascot.png     # 吉祥物图片
└── CLAUDE.md                      # Claude Code 项目指引
```

## 技术栈

- Swift 6 + SwiftUI
- Swift Charts（圆环图）
- AppKit（NSPanel 边缘触发、NSEvent 全局鼠标监控）
- Combine / Timer（30 分钟轮询）
- [Sparkle 2.x](https://github.com/sparkle-project/Sparkle)（应用内自动更新）
- GitHub Actions（tag push 触发 release + ad-hoc 签 + appcast 发布）

## 发布流程

```bash
git tag v0.2.0
git push --tags
```

CI 自动：build → ad-hoc 签 → zip → EdDSA 签 → GitHub Release → 提交 `gh-pages` 分支托管 appcast。用户启动 app 后 Sparkle 自动检测并提示升级。
