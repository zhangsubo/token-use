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

### 方式一：直接运行

```bash
git clone https://github.com/zhangsubo/token-use.git
cd token-use
./build.sh
cp -R TokenUse.app ~/Applications/
open ~/Applications/TokenUse.app
```

### 方式二：开发调试

```bash
swift run
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
