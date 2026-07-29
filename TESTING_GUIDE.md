# TokenUse 测试指南

## 📦 测试包信息

- **文件名**: `TokenUse.zip` (6.6MB)
- **架构**: arm64 (Apple Silicon)
- **签名**: Ad-hoc (本地测试用)
- **版本**: 带 OpenCode 支持和智能缓存

## 🧪 测试步骤

### 1. 安装测试

```bash
# 解压（如需要）
unzip TokenUse.zip

# 直接打开
open TokenUse.app
```

### 2. 首次启动测试（预期：~10秒）

**测试目标**：验证所有数据源扫描正常

**步骤**：
1. 确保之前没有缓存（或删除）：`rm -rf ~/Applications/token-use/`
2. 打开应用：`open TokenUse.app`
3. 观察右侧屏幕边缘，悬停鼠标查看面板
4. 检查数据是否显示（预期：26+ entries）

**预期结果**：
- ✅ 应用在 ~10 秒内显示数据
- ✅ 面板显示 "All Time" 和 "Today" 统计
- ✅ OpenCode 数据正常加载（如果你使用 OpenCode）
- ✅ 总成本显示准确

### 3. 缓存启动测试（预期：<3秒）

**测试目标**：验证缓存系统工作正常

**步骤**：
1. 关闭应用（右键菜单栏图标 → Quit，或 `pkill TokenUse`）
2. 等待 2 秒
3. 再次打开：`open TokenUse.app`
4. 立即悬停鼠标到右侧屏幕边缘

**预期结果**：
- ✅ 应用在 <3 秒内显示数据
- ✅ 数据立即可见（使用缓存）
- ✅ 状态可能显示 "Loaded from cache"

### 4. 功能测试

**测试项目**：
- [ ] 右侧屏幕边缘触发区域正常工作
- [ ] 面板滑出/滑入动画流畅
- [ ] "All Time" 显示历史总计
- [ ] "Today" 显示今日数据
- [ ] 甜甜圈图表正常渲染
- [ ] 设置面板可以打开（如果有）
- [ ] 刷新功能正常（如果手动触发）

### 5. 数据验证

**检查数据源是否完整加载**：

```bash
# 查看最新报告
cat ~/Applications/token-use/report/report-*.json | tail -1 | jq '{
  totalEntries: (.entries | length),
  totalCost,
  clients: [.entries[] | .client] | unique
}'
```

**预期输出**：
```json
{
  "totalEntries": 26,
  "totalCost": 3180+,
  "clients": ["claude", "codex", "kimi", "mimocode", "opencode"]
}
```

### 6. 调试日志检查

```bash
# 实时查看日志
tail -f ~/Applications/token-use/debug.log

# 或查看完整日志
cat ~/Applications/token-use/debug.log
```

**关键日志标记**：
- ✅ `✅ [AppState] 缓存有效，立即加载缓存数据` - 缓存命中
- ✅ `✅ [NativeUsage] SQLite 直接查询成功` - OpenCode 正常
- ✅ `✅ [AppState] 数据更新成功` - 数据加载完成
- ✅ `🚀 [AppState] start() 完成` - 启动完成

## 🐛 问题排查

### 应用无法启动
```bash
# 检查进程
ps aux | grep TokenUse

# 查看日志
cat ~/Applications/token-use/debug.log
```

### 数据不显示
```bash
# 检查缓存文件
ls -lh ~/Applications/token-use/report/

# 查看最新报告
cat ~/Applications/token-use/report/report-*.json | tail -1 | jq .
```

### OpenCode 数据缺失

**可能原因**：
1. 你没有使用 OpenCode
2. OpenCode 数据库路径不是 `~/.local/share/opencode/opencode.db`
3. 数据库为空或没有最近 90 天的数据

**验证**：
```bash
# 检查 OpenCode 数据库
ls -lh ~/.local/share/opencode/*.db

# 查询数据库
sqlite3 ~/.local/share/opencode/opencode.db "SELECT COUNT(*) FROM session;"
```

### 缓存不生效

```bash
# 检查缓存文件修改时间
ls -lh ~/Applications/token-use/report/

# 如果文件超过 1 小时，缓存会过期，属于正常行为
```

## 📊 性能基准

| 场景 | 预期时间 | 说明 |
|------|---------|------|
| 首次启动（无缓存） | ~10秒 | 扫描所有日志源 |
| 缓存启动 | <3秒 | 立即加载缓存 |
| 后台今日数据更新 | ~3秒 | 用户无感知 |
| 缓存有效期 | 1小时 | 自动失效 |

## ✅ 验收标准

测试通过需满足：

- [ ] 首次启动时间 ≤ 15 秒
- [ ] 缓存启动时间 ≤ 5 秒
- [ ] 数据条目数 ≥ 5
- [ ] 所有使用的 AI 工具数据都被统计
- [ ] 面板交互流畅无卡顿
- [ ] 无崩溃或明显错误

## 🆘 反馈问题

如果遇到问题，请提供：

1. **日志文件**：`~/Applications/token-use/debug.log`
2. **报告文件**：最新的 `~/Applications/token-use/report/report-*.json`
3. **问题描述**：详细步骤和预期 vs 实际结果
4. **系统信息**：macOS 版本和芯片型号

---

## 🎯 新特性测试重点

### 1. OpenCode 支持
- 检查是否有 OpenCode 条目
- 验证 OpenCode 成本统计

### 2. 缓存系统
- 第一次启动较慢（正常）
- 第二次启动很快（<3秒）
- 关闭重开多次验证缓存稳定性

### 3. 数据完整性
- 对比之前的统计，数据应该更完整
- OpenCode 数据（如果使用）应该出现

---

**祝测试顺利！** 🚀
