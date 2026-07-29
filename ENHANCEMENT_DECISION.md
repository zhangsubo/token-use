# TokenUse 增强方案讨论

## 背景

你要求我学习 tokscale 的实现，增强 TokenUse 的分析能力，支持：
1. 更多 Client 的 Data Location
2. tokscale 的 Pricing 能力（不考虑 Custom Pricing）

## tokscale 的核心能力

### 1. 支持的数据源
- **40+ 个 AI 编程助手客户端**
- 包括：Cursor、Copilot、Cline、Zed、Warp、Gemini CLI、Qwen CLI 等
- 不同格式：SQLite、JSONL、JSON、CSV、API 同步

### 2. 定价系统
- **多级查找策略**：
  1. Custom Pricing Overrides（你说不需要）
  2. LiteLLM 精确匹配
  3. 别名解析
  4. 移除后缀重试
  5. 版本标准化
  6. Provider 前缀匹配
  7. Cursor 模型定价
  8. OpenRouter 动态回退
  9. 模糊匹配

- **数据源**：
  - LiteLLM pricing API (主要)
  - OpenRouter API (回退)
  - Cursor docs (最新模型)
  - 1小时磁盘缓存

## 我的初步实现

我已经创建了：
1. `EnhancedPricingResolver.swift` - 多级定价查找
2. `ExtendedDataSources.swift` - Cursor、Copilot、Cline、Zed 数据源

**但实现过程中我意识到问题：**

### 问题 1: 工作量巨大
- 40+ 数据源需要逐个实现和测试
- 不同格式需要不同的解析逻辑
- 维护成本高

### 问题 2: 复杂度激增
- 动态 API 调用增加网络依赖
- 缓存管理变复杂
- 错误处理更困难

### 问题 3: 实际价值存疑
- 当前 5 个数据源已覆盖主流
- 大部分用户不会用到 40+ 客户端
- 定价准确性：现有 PriceResolver 已基本满足

## 三个方案供你选择

### 方案 A: 完整实施（高成本）

**实施内容**：
- ✅ 集成 LiteLLM/OpenRouter API
- ✅ 实现多级定价查找
- ✅ 添加 10-20 个常用数据源
- ✅ 完整的缓存系统

**优点**：
- 功能最全面
- 与 tokscale 能力接近

**缺点**：
- 开发时间：2-3 天
- 代码复杂度大幅增加
- 维护成本高
- 可能引入新 bug

**建议优先级**：❌ 不推荐（过度工程）

---

### 方案 B: 选择性增强（平衡）⭐ 推荐

**实施内容**：
- ✅ 改进 PriceResolver（手动更新价格表）
- ✅ 添加 3-5 个高价值数据源（Cursor、Copilot、Cline）
- ❌ 不集成动态 API
- ❌ 保持简单架构

**优点**：
- 工作量适中（4-6 小时）
- 显著提升价值
- 保持代码简洁
- 风险可控

**缺点**：
- 不如 tokscale 全面
- 价格需要手动更新

**建议优先级**：⭐ 推荐（实用主义）

---

### 方案 C: 保持现状（低成本）

**实施内容**：
- ✅ 仅更新 PriceResolver 价格表
- ✅ 完善文档
- ❌ 不添加新数据源

**优点**：
- 工作量最小（1 小时）
- 零风险
- 已有功能稳定运行

**缺点**：
- 功能无显著提升
- 错过学习 tokscale 的机会

**建议优先级**：✅ 可接受（如果满足需求）

## 我的建议

**推荐方案 B**，原因：

1. **实用性**：添加 Cursor、Copilot、Cline 这几个真正广泛使用的工具
2. **可行性**：工作量适中，4-6 小时可完成
3. **可维护性**：不增加动态 API 依赖，保持架构简洁
4. **价值**：显著提升数据完整性和准确性

## 具体实施计划（方案 B）

### 第一步：改进定价（1-2小时）
- 更新 PriceResolver.swift 价格表
- 参考 LiteLLM 最新数据
- 添加最新模型（如 gpt-5.x、claude-opus-5 等）

### 第二步：添加数据源（3-4小时）
1. **Cursor** - CSV 导出格式（如果用户使用）
2. **Copilot** - JSONL OTEL 格式
3. **Cline** - VS Code globalStorage JSON

### 第三步：测试和文档（1小时）
- 测试新数据源
- 更新 CLAUDE.md
- 添加使用说明

**总工作量：5-7 小时**

## 请你决定

请告诉我：

1. **选择哪个方案？** (A / B / C)
2. **如果选 B，优先哪些数据源？**
   - Cursor IDE？
   - Copilot CLI？
   - Cline？
   - 其他？
3. **对定价系统的期望？**
   - 静态价格表就够？
   - 需要动态 API？

根据你的选择，我会调整实施计划并开始工作。
