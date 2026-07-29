# TokenUse 增强计划 - 参考 tokscale

## 目标

基于 https://github.com/junhoyeo/tokscale 的实现，增强 TokenUse 的 token 分析能力。

## 需要增强的功能

### 1. 扩展支持的 Client 数据源

**当前支持** (5个):
- Claude Code: `~/.claude/projects/`
- Codex CLI: `~/.codex/sessions/`
- Kimi CLI: `~/.kimi/sessions/`
- MiMo Code: `~/.mimo/sessions/`
- OpenCode: `~/.local/share/opencode/opencode.db`

**tokscale 支持** (40+ 个客户端):
- OpenClaw: `~/.openclaw/agents/` (+ legacy: `.clawdbot`, `.moltbot`, `.moldbot`)
- Copilot CLI: `~/.copilot/otel/*.jsonl`
- Hermes Agent: `$HERMES_HOME/state.db`
- Gemini CLI: `$GEMINI_CLI_HOME/tmp/*/chats/*.json`
- Cursor IDE: 缓存导出 `~/.config/tokscale/cursor-cache/usage*.csv`
- Amp: `~/.local/share/amp/threads/`
- Codebuff: `~/.config/manicode/`
- Droid: `~/.factory/sessions/`
- Pi: `~/.pi/agent/sessions/` 和 `~/.omp/agent/sessions/`
- Qwen CLI: `~/.qwen/projects/`
- Roo Code: VS Code globalStorage `rooveterinaryinc.roo-cline/tasks/`
- Kilo: VS Code globalStorage `kilocode.kilo-code/tasks/`
- Kilo CLI: `~/.local/share/kilo/kilo.db`
- Mux: `~/.mux/sessions/`
- Crush: `$XDG_DATA_HOME/crush/projects.json`
- Goose: `~/.local/share/goose/sessions/sessions.db`
- Antigravity: 通过 RPC 同步
- Antigravity CLI: `~/.gemini/antigravity-cli/conversations/*.db`
- Trae: 通过 API 同步
- Warp: 通过 API 同步
- Grok Build: `$GROK_HOME/sessions/*/*/updates.jsonl`
- Zed Agent: `~/.local/share/zed/threads/threads.db`
- Kiro: `~/.kiro/sessions/cli/*.json`
- Cline: VS Code globalStorage `saoudrizwan.claude-dev/tasks/`
- Gajae-Code: `~/.gjc/agent/sessions/`
- Jcode: `~/.jcode/sessions/session_*.json`
- Junie: `~/.junie/sessions/*/events.jsonl`
- Command Code: `~/.commandcode/projects/**/*.jsonl`
- ZCode: `~/.zcode/cli/db/db.sqlite`
- OpenCodeReview: `~/.opencodereview/sessions/**/*.jsonl`
- CodeBuddy: `~/.codebuddy/projects/**/*.jsonl`
- WorkBuddy: `~/.workbuddy/projects/**/*.jsonl`
- Devin CLI: `~/.local/share/devin/cli/sessions.db`
- Devin Desktop: ACP events 目录
- Synthetic/Octofriend: `~/.local/share/octofriend/sqlite.db`

### 2. 增强 Pricing 能力

**当前实现**:
- 使用 PriceResolver.swift 估算成本
- 硬编码的价格数据

**tokscale Pricing 策略** (多级查找):

1. **Custom Pricing Overrides** - 用户自定义 `~/.config/tokscale/custom-pricing.json`
2. **Exact Match** - LiteLLM/OpenRouter 精确匹配
3. **Alias Resolution** - 别名解析 (如 `big-pickle` → `glm-4.7`)
4. **Tier Suffix Stripping** - 移除质量等级后缀 (`gpt-5.2-xhigh` → `gpt-5.2`)
5. **Version Normalization** - 版本格式处理 (`claude-3-5-sonnet` ↔ `claude-3.5-sonnet`)
6. **Provider Prefix Matching** - 尝试常见前缀 (`anthropic/`, `openai/`)
7. **Cursor Model Pricing** - 新模型硬编码定价
8. **Fuzzy Matching** - 部分匹配

**定价数据源**:
- LiteLLM pricing database (主要)
- OpenRouter endpoints API (动态回退)
- Cursor model docs (最新模型)
- 1小时磁盘缓存

**Provider 偏好**:
- 优先原始提供商 (`xai/`, `anthropic/`, `openai/`, `google/`)
- 降低转售商优先级 (`azure_ai/`, `bedrock/`, `vertex_ai/`)

**支持的 Token 类型**:
- Input tokens
- Output tokens
- Cache read tokens (折扣)
- Cache write tokens
- Reasoning tokens (o1系列)
- 分级定价 (超过200k/272k tokens)

### 3. 新增数据源优先级

**优先实现** (常用 + 易实现):
1. ✅ Cursor IDE (已在很多项目中使用)
2. ✅ Copilot CLI (GitHub官方)
3. ✅ Cline (VS Code 流行插件)
4. ✅ Roo Code (Cline 分支)
5. ✅ Zed Agent (新兴编辑器)
6. ✅ Warp (流行终端)

**次优先级** (特定用户群):
7. Gemini CLI
8. Qwen CLI
9. Pi
10. Goose
11. Antigravity

**低优先级** (小众或商业):
- Cursor/Trae/Warp 需要 API 同步
- Devin (商业产品)
- 其他小众工具

## 实施计划

### Phase 1: 增强定价系统
- [ ] 实现多级定价查找策略
- [ ] 集成 LiteLLM pricing API
- [ ] 添加 OpenRouter 动态回退
- [ ] 实现定价缓存 (1小时TTL)
- [ ] 支持自定义定价覆盖

### Phase 2: 扩展常用数据源
- [ ] Cursor IDE (缓存导出)
- [ ] Copilot CLI (OTEL JSONL)
- [ ] Cline (VS Code globalStorage)
- [ ] Roo Code (VS Code globalStorage)
- [ ] Zed Agent (SQLite)
- [ ] Warp (API 同步)

### Phase 3: 扩展更多数据源
- [ ] Gemini CLI
- [ ] Qwen CLI
- [ ] Pi
- [ ] Goose
- [ ] 其他常用工具

### Phase 4: 优化和完善
- [ ] 统一数据源接口
- [ ] 改进错误处理
- [ ] 添加进度显示
- [ ] 性能优化

## 技术架构

### 定价系统
```swift
protocol PricingProvider {
    func fetchPricing(model: String) async throws -> ModelPricing
}

class LiteLLMProvider: PricingProvider { ... }
class OpenRouterProvider: PricingProvider { ... }
class CustomPricingProvider: PricingProvider { ... }

class PricingResolver {
    private let providers: [PricingProvider]
    private let cache: PricingCache
    
    func resolve(model: String, provider: String?) async -> ModelPricing?
}
```

### 数据源系统
```swift
protocol UsageDataSource {
    var name: String { get }
    var dataLocation: String { get }
    func scan(interval: DateInterval) async throws -> [UsageEntry]
}

class CursorDataSource: UsageDataSource { ... }
class CopilotDataSource: UsageDataSource { ... }
class ClineDataSource: UsageDataSource { ... }

class DataSourceRegistry {
    func registerAll()
    func scanAll(interval: DateInterval) async -> [UsageEntry]
}
```

## 参考资源

- tokscale README: https://github.com/junhoyeo/tokscale/blob/main/README.md
- LiteLLM pricing: https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json
- OpenRouter API: https://openrouter.ai/docs/api/api-reference/endpoints/list-endpoints
- Cursor models: https://cursor.com/en-US/docs/models

## 注意事项

1. **不实现 Custom Pricing** - 用户不需要手动维护定价文件
2. **专注常用工具** - 优先实现使用广泛的数据源
3. **保持简单** - 避免过度复杂的同步机制
4. **性能优先** - 使用缓存和异步并发
5. **兼容性** - 保持现有功能正常工作
