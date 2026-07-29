# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- 使用原生日志扫描替代 tokscale CLI 依赖
- 优化启动性能：智能缓存策略（首次 ~8s，后续 <1s）
- All Time 范围限制为 90 天（避免 OpenCode 数据库查询超时）

### Added
- 支持 OpenCode 数据源（通过 SQLite.swift 直接查询数据库）
- 新增 `DEVELOPMENT.md` 开发文档
- 内置定价计算器（PriceResolver），支持 20+ 模型

### Fixed
- 修复今日 token 统计为 0 的问题
- 优化错误处理和日志输出

## [0.2.0] - 2026-07-XX

### Added
- Sparkle 自动更新支持
- 设置面板（刷新间隔、自定义吉祥物、自动更新开关）
- 边缘触发面板（屏幕边缘悬停触发）

### Changed
- 升级到 Swift 6（严格并发检查）
- 改进 UI 视觉效果（多层毛玻璃渐变）

## [0.1.0] - 2026-06-XX

### Added
- 首个公开版本
- 基于 tokscale CLI 的数据获取
- 圆环图可视化
- 全量和今日统计
