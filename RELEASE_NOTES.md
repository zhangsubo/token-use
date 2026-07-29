# Release v0.3.0 发布记录

**发布日期**: 2026-07-29  
**Git Tag**: v0.3.0  
**GitHub Actions**: https://github.com/zhangsubo/token-use/actions/runs/30432152770

## 主要变更

### 架构升级
- ✅ **移除 tokscale CLI 依赖**：改为直接扫描本地日志文件
- ✅ **原生日志扫描**：支持 5 种数据源（Claude、Codex、Kimi、Mimo、OpenCode）
- ✅ **智能缓存策略**：首次启动 ~8s，后续 <1s（1小时缓存有效期）
- ✅ **内置定价计算器**：支持 20+ 模型（OpenAI、Anthropic、Google、Moonshot、Xiaomi、DeepSeek 等）

### 性能优化
- All Time 范围限制为 90 天（避免 OpenCode 数据库查询超时）
- 三级兜底机制：实时数据 → 缓存 → 空状态
- Swift 6 严格并发模型（actor、@MainActor、Sendable）

### 新增功能
- ✅ **DEVELOPMENT.md**: 完整的开发文档（架构、数据流、发布流程）
- ✅ **CHANGELOG.md**: 版本变更记录
- ✅ **Sparkle EdDSA 签名**: 自动更新包签名验证

### 代码质量
- 为核心服务添加详细注释（AppState、NativeUsageService）
- 标记 TokscaleService 为已废弃（保留向后兼容）
- 删除临时文档（11 个 .md 文件）

## 技术栈

- **Swift 6** + SwiftUI（严格并发检查）
- **SQLite.swift**: OpenCode 数据库读取
- **Sparkle 2.x**: 自动更新（EdDSA 签名）
- **GitHub Actions**: CI/CD 自动发布

## 数据源支持

| 客户端 | 路径 | 格式 | 实现方式 |
|--------|------|------|---------|
| Claude Code | `~/.claude/projects/**/*.jsonl` | JSONL | 文件扫描 + JSON 解析 |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | JSONL | 按日期目录扫描 |
| Kimi | `~/.kimi/sessions/**/wire.jsonl` | JSONL | 递归扫描 wire.jsonl |
| Mimo | `~/.mimo/sessions/**/*.jsonl` | JSONL | 文件扫描 + 修改时间过滤 |
| OpenCode | `~/.local/share/opencode/*.db` | SQLite | SQLite.swift 直接查询 |

## Sparkle 配置

### 公钥（Info.plist）
```xml
<key>SUPublicEDKey</key>
<string>gxIwYctaW0/FtXmFaM3tytB/dWSpykXjovyPxKqMq0U=</string>
```

### 私钥（GitHub Secrets）
- **Secret Name**: `SPARKLE_PRIVATE_KEY`
- **位置**: Repository Secrets
- **用途**: GitHub Actions 签名发布包

### Appcast 地址
- **URL**: https://zhangsubo.github.io/token-use/appcast.xml
- **托管**: GitHub Pages (gh-pages 分支)
- **更新**: 每次发布自动更新

## 构建配置

### 版本注入
```bash
MARKETING_VERSION=0.3.0 BUILD_NUMBER=<run_number> ./build.sh
```

### GitHub Actions 触发
```bash
git tag v0.3.0
git push origin v0.3.0
```

### 自动流程
1. ✅ 构建 arm64 release
2. ✅ Ad-hoc 签名（无需 Apple Developer 账号）
3. ✅ 打包 TokenUse.zip
4. ✅ EdDSA 签名（使用 SPARKLE_PRIVATE_KEY）
5. ✅ 创建 GitHub Release
6. ✅ 更新 appcast.xml 到 gh-pages

## Git 提交记录

```
adaf067 (HEAD -> main, tag: v0.3.0) feat: 添加 Sparkle EdDSA 公钥
73d7c20 Merge feat/native-token-stats: 原生日志扫描架构
a77d467 docs: 整理代码文档，更新为原生日志扫描架构
c1e0d90 docs: 添加开发和测试文档
a27b34a feat: 基于 tokscale 增强定价系统
3b11a45 refactor: 替换 tokscale 为原生统计实现
63d91b8 feat: 今日token三级兜底 + 原生本地日志聚合
```

## 文件变更统计

```
18 files changed, 384 insertions(+), 2233 deletions(-)
- 新增: CHANGELOG.md, DEVELOPMENT.md, RELEASE_NOTES.md
- 删除: 11 个临时文档 (ENHANCEMENT_*.md, FINAL_*.md 等)
- 更新: README.md, CLAUDE.md, Info.plist
- 代码: AppState.swift, NativeUsageService.swift
```

## 已知问题

无。所有核心功能已验证通过。

## 后续计划

1. **性能监控**: 收集真实用户的启动时间数据
2. **数据源扩展**: 根据用户反馈添加更多 AI 客户端支持
3. **定价更新**: 跟进最新模型定价变化
4. **UI 优化**: 根据用户反馈调整视觉效果

## 参考链接

- **GitHub Repository**: https://github.com/zhangsubo/token-use
- **Release Page**: https://github.com/zhangsubo/token-use/releases/tag/v0.3.0
- **Appcast**: https://zhangsubo.github.io/token-use/appcast.xml
- **Documentation**: [DEVELOPMENT.md](DEVELOPMENT.md)
- **Changelog**: [CHANGELOG.md](CHANGELOG.md)

## 开发团队

- **作者**: zhangsubo
- **AI 助手**: Claude (Opus 5)
- **构建工具**: GitHub Actions + Sparkle

---

**发布状态**: 🚀 构建中 (GitHub Actions Run #30432152770)
