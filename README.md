# TokenUse

macOS 菜单栏应用，可视化展示 tokscale 的 Token 使用量统计。

## 功能

- **自动检测安装**：首次启动时检查 tokscale 是否安装，未安装则提示并支持一键自动安装
- **定时数据收集**：每 30 分钟自动执行 `tokscale models --json`，导出到 `~/Applications/token-use/report/`
- **圆环图展示**：左侧显示前 5 大模型 + Others 的 Token 使用占比
- **详细统计**：右侧显示全量总量、预计价格、今日使用量、今日金额及更新时间
- **深色/浅色模式自适应**：遵循 macOS HIG 设计规范

## 系统要求

- macOS 14.0+
- Node.js + npm（用于安装 tokscale）

## 安装与运行

### 方式一：直接运行

```bash
git clone <repo>
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
├── Package.swift              # SPM 包配置
├── Sources/TokenUse/
│   ├── AppDelegate.swift      # 菜单栏逻辑与生命周期
│   ├── AppState.swift         # 全局状态管理与定时任务
│   ├── ContentView.swift      # 主面板容器
│   ├── Models/
│   │   └── TokenData.swift    # 数据模型
│   ├── Views/
│   │   ├── DonutChartView.swift   # 圆环图
│   │   └── StatsPanelView.swift   # 统计面板
│   ├── Services/
│   │   └── TokscaleService.swift  # tokscale CLI 调用
│   └── Utilities/
│       └── ReportManager.swift    # 报告文件管理
└── build.sh                   # 打包脚本
```

## 技术栈

- Swift 6 + SwiftUI
- Swift Charts（圆环图）
- AppKit（NSStatusBar / NSPopover）
- Combine / Timer
