# AgentAPI Gateway 设计方案

> 一个本地统一的 AI API 接入网关 + MCP Skill Registry。目标：让任何 Agent（Claude Code、Kimi、TechMarkdown 等）不再重复维护各家 LLM 的 API 调用方式，而是通过统一的 MCP Tools 或 OpenAI-Compatible REST API 访问所有模型，并集中管理 key、提示词、用量统计。

---

## 1. 问题定义

当前开发 Agent 时常见的痛点：

| 痛点 | 表现 |
|------|------|
| 接口不一致 | OpenAI、Anthropic、Gemini、Azure、国内厂商各自一套 SDK/字段 |
| Key 分散 | 每个 Agent/项目都要单独配置 API key，容易泄漏、难轮换 |
| 模型信息滞后 | Agent 训练数据里的模型列表、接口方式经常过时 |
| 无法统计 | 不知道哪个 Agent、哪个模型、哪个 prompt 花了多少 token |
| 提示词不统一 | 每个项目各自写 system prompt，难以沉淀和 A/B 测试 |
| 接入重复 | 每做一个 Agent 都要重新写一遍 HTTP 调用、重试、流式解析 |

**AgentAPI Gateway 的目标**：把这些差异全部收敛到本地一层，对外只暴露「模型名 + 消息」即可。

---

## 2. 服务定位

- **独立服务**：不嵌入 TechMarkdown，单独仓库/二进制/容器运行。
- **本地优先**：默认监听 `127.0.0.1`，数据不出本机（可配置远程）。
- **协议双模**：
  1. **MCP Server**（推荐）：Agent 通过 `tools` 调用，零代码集成。
  2. **OpenAI-Compatible REST API**：兼容现有 SDK 和代码。
- **Provider 无关**：内置多家云厂商协议转换，新增 provider 只需写 adapter。

---

## 3. 推荐技术栈

| 层级 | 选型 | 理由 |
|------|------|------|
| 运行时 | Node.js 20+ + TypeScript | MCP SDK 官方支持最好，生态成熟，跨平台 |
| Web 框架 | Fastify | 高性能、流式响应友好、插件丰富 |
| MCP | `@modelcontextprotocol/sdk` | 官方 SDK，支持 stdio / SSE |
| 配置 | YAML + 热重载 | 人类可读，改完立即生效 |
| 数据 | SQLite（本地） | 用量、prompt 版本 lightweight 存储 |
| 部署 | npm 全局 CLI / Docker / Homebrew | 本地一键启动 |

> 备选：若团队更熟悉 Python，可用 FastAPI + mcp-python-sdk，接口设计完全沿用本文档。

---

## 4. 整体架构

```text
┌─────────────────────────────────────────────────────────────┐
│                      Agent Clients                          │
│   Claude Code · Kimi Code · TechMarkdown · 自定义 Agent      │
└──────────────────────┬──────────────────────────────────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
   MCP stdio      MCP SSE        REST API
        │              │              │
└───────┴──────────────┴──────────────┴───────────────────────┘
│                AgentAPI Gateway (localhost:8787)            │
│  ┌──────────────┐ ┌──────────────┐ ┌─────────────────────┐  │
│  │ MCP Server   │ │ REST Router  │ │ Provider Adapters   │  │
│  │   Tools      │ │  /v1/...     │ │ OpenAI/Anthropic/.. │  │
│  └──────────────┘ └──────────────┘ └─────────────────────┘  │
│  ┌──────────────┐ ┌──────────────┐ ┌─────────────────────┐  │
│  │ Model Reg.   │ │ Prompt Reg.  │ │ Usage Tracker       │  │
│  │ Capability   │ │ Templates    │ │ SQLite              │  │
│  └──────────────┘ └──────────────┘ └─────────────────────┘  │
└──────────────────────┬──────────────────────────────────────┘
                       │ Unified outbound HTTP
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
    OpenAI        Anthropic         Gemini
   Azure OAI     国内厂商 API      Local LLM
```

---

## 5. 目录结构（服务仓库）

```text
agentapi-gateway/
├── src/
│   ├── index.ts                 # 入口：启动 REST + MCP
│   ├── config.ts                # 配置读取与热重载
│   ├── server/
│   │   ├── rest.ts              # Fastify REST 路由
│   │   └── mcp.ts               # MCP Server 实现
│   ├── providers/
│   │   ├── openai.ts            # OpenAI 协议适配
│   │   ├── anthropic.ts         # Anthropic 协议适配
│   │   ├── gemini.ts            # Gemini 协议适配
│   │   ├── azure-openai.ts      # Azure OpenAI 适配
│   │   └── index.ts             # Provider 注册表
│   ├── registry/
│   │   ├── models.ts            # 模型元数据
│   │   └── prompts.ts           # 提示词模板
│   ├── tracker/
│   │   └── usage.ts             # 用量统计 SQLite 逻辑
│   └── types.ts                 # 公共类型
├── config/
│   └── example.config.yaml      # 示例配置
├── scripts/
│   └── install-service.sh       # macOS launchd / Linux systemd
├── Dockerfile
├── package.json
├── tsconfig.json
└── README.md
```

---

## 6. 核心配置文件

路径：`~/.agentapi/config.yaml`

```yaml
server:
  host: 127.0.0.1
  port: 8787
  # MCP 传输方式：stdio | sse
  mcpTransport: sse

providers:
  openai:
    baseURL: https://api.openai.com/v1
    apiKey: ${OPENAI_API_KEY}
    defaultModel: gpt-4o-mini
    models:
      - gpt-4o
      - gpt-4o-mini
      - o3-mini

  anthropic:
    baseURL: https://api.anthropic.com
    apiKey: ${ANTHROPIC_API_KEY}
    defaultModel: claude-3-5-sonnet-20241022
    models:
      - claude-3-5-sonnet-20241022
      - claude-3-opus-20240229

  gemini:
    baseURL: https://generativelanguage.googleapis.com/v1beta
    apiKey: ${GEMINI_API_KEY}
    defaultModel: gemini-2.0-flash

  # 自定义 / 内部模型
  custom-deepseek:
    baseURL: https://api.deepseek.com
    apiKey: ${DEEPSEEK_API_KEY}
    adapter: openai  # 复用 OpenAI 协议适配器
    defaultModel: deepseek-v4-flash
    models:
      - deepseek-v4-flash
      - deepseek-v4-pro

prompts:
  - id: concise-coder
    name: 极简程序员
    system: >
      你是一个资深工程师。回答必须简洁、可执行，优先给出代码和命令。
  - id: tech-markdown-helper
    name: TechMarkdown 助手
    system: >
      你擅长 Markdown 编辑、文档结构优化和 macOS Swift 开发。
      用户可能让你分析项目文件、生成文档或修改 Markdown。

usage:
  # 是否持久化到 SQLite
  persist: true
  dbPath: ~/.agentapi/usage.sqlite
  # 费用估算（按 1K tokens）
  pricing:
    "openai/gpt-4o":
      input: 0.005
      output: 0.015
```

---

## 7. MCP Tools 接口（Agent 侧直接调用）

这是**推荐接入方式**。Agent 不需要关心底层 provider，只需要调用 tools。

### Tool: `agentapi_list_models`

```json
{
  "name": "agentapi_list_models",
  "description": "列出当前网关可用的所有模型及其能力标签",
  "inputSchema": {
    "type": "object",
    "properties": {
      "provider": { "type": "string", "description": "可选，按 provider 过滤" }
    }
  }
}
```

返回示例：

```json
[
  { "id": "openai/gpt-4o", "provider": "openai", "capabilities": ["vision", "json", "streaming"] },
  { "id": "anthropic/claude-3-5-sonnet-20241022", "provider": "anthropic", "capabilities": ["vision", "streaming"] }
]
```

### Tool: `agentapi_chat_completion`

```json
{
  "name": "agentapi_chat_completion",
  "description": "统一的聊天补全接口，自动路由到对应 provider",
  "inputSchema": {
    "type": "object",
    "properties": {
      "model": { "type": "string", "description": "模型 ID，如 openai/gpt-4o" },
      "messages": { "type": "array" },
      "temperature": { "type": "number" },
      "stream": { "type": "boolean" },
      "promptId": { "type": "string", "description": "可选，引用预置 system prompt" },
      "extraHeaders": { "type": "object" }
    },
    "required": ["model", "messages"]
  }
}
```

返回示例（非流式）：

```json
{
  "id": "chatcmpl-xxx",
  "model": "openai/gpt-4o",
  "content": "...",
  "usage": { "promptTokens": 120, "completionTokens": 80, "totalTokens": 200 }
}
```

### Tool: `agentapi_list_prompts`

```json
{
  "name": "agentapi_list_prompts",
  "description": "列出预置的提示词模板"
}
```

### Tool: `agentapi_apply_prompt`

```json
{
  "name": "agentapi_apply_prompt",
  "description": "把提示词模板应用到 messages 上",
  "inputSchema": {
    "type": "object",
    "properties": {
      "promptId": { "type": "string" },
      "messages": { "type": "array" },
      "variables": { "type": "object" }
    },
    "required": ["promptId", "messages"]
  }
}
```

### Tool: `agentapi_get_usage`

```json
{
  "name": "agentapi_get_usage",
  "description": "查询用量统计",
  "inputSchema": {
    "type": "object",
    "properties": {
      "start": { "type": "string", "description": "ISO 日期，如 2026-06-01" },
      "end": { "type": "string" },
      "groupBy": { "enum": ["model", "provider", "agent", "day"] }
    }
  }
}
```

---

## 8. REST API 接口（兼容 OpenAI SDK）

用于已有代码或 Swift app 直接通过 HTTP 调用。

### Base URL

```text
http://127.0.0.1:8787
```

### 认证

使用网关自身的 API key（可选，默认关闭）：

```bash
curl http://127.0.0.1:8787/v1/chat/completions \
  -H "Authorization: Bearer gateway-local-key" \
  -H "Content-Type: application/json" \
  -d '{...}'
```

### 端点列表

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/health` | 健康检查 |
| GET | `/v1/models` | 列出可用模型 |
| POST | `/v1/chat/completions` | 统一聊天补全（流式/非流式） |
| POST | `/v1/completions` | 文本补全 |
| GET | `/v1/usage` | 用量查询 |
| GET | `/v1/prompts` | 提示词列表 |
| POST | `/v1/prompts/:id/apply` | 应用提示词模板 |
| GET | `/v1/providers` | 已配置 provider 状态 |

### 请求示例

```bash
curl http://127.0.0.1:8787/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-3-5-sonnet-20241022",
    "messages": [{"role": "user", "content": "你好"}],
    "stream": false
  }'
```

响应示例：

```json
{
  "id": "msg_01xxx",
  "object": "chat.completion",
  "created": 1718000000,
  "model": "anthropic/claude-3-5-sonnet-20241022",
  "choices": [{
    "index": 0,
    "message": { "role": "assistant", "content": "你好！有什么可以帮你的？" },
    "finish_reason": "stop"
  }],
  "usage": { "prompt_tokens": 10, "completion_tokens": 15, "total_tokens": 25 }
}
```

---

## 9. 模型路由规则

- `model` 字段使用 `provider/model-id` 格式，例如 `openai/gpt-4o`、`anthropic/claude-3-5-sonnet-20241022`。
- 网关根据 `/` 前面部分定位 provider adapter，后面部分作为实际模型 ID。
- 如果只有一个 provider 配置，可省略前缀，直接用 `gpt-4o`，网关默认走第一个 OpenAI 兼容 provider。
- 如果模型未找到，返回 `400` 并给出可用模型列表，避免 Agent 乱猜。

---

## 10. Provider Adapter 设计

每个 adapter 必须实现统一接口：

```typescript
interface ProviderAdapter {
  name: string;
  chatCompletion(request: ChatRequest): AsyncIterable<ChatChunk> | Promise<ChatResponse>;
  listModels(): Promise<ModelInfo[]>;
}
```

新增 provider 只需：

1. 在 `config.yaml` 增加 provider 项。
2. 在 `src/providers/` 新增 adapter（或复用 `openai` adapter）。
3. 重启/热重载网关。

---

## 11. 部署方式

### 方式 A：本地开发（推荐先这样跑）

```bash
# 1. 安装
npm install -g agentapi-gateway

# 2. 生成默认配置
agentapi init

# 3. 编辑 ~/.agentapi/config.yaml，填入 keys

# 4. 启动 REST + MCP SSE
agentapi start
```

### 方式 B：Docker

```bash
docker run -d \
  --name agentapi \
  -p 127.0.0.1:8787:8787 \
  -v ~/.agentapi:/root/.agentapi \
  -e OPENAI_API_KEY=$OPENAI_API_KEY \
  -e ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY \
  agentapi-gateway:latest
```

### 方式 C：macOS 系统服务

```bash
agentapi install-service
# 自动写入 ~/Library/LaunchAgents/com.agentapi.gateway.plist
launchctl load -w ~/Library/LaunchAgents/com.agentapi.gateway.plist
```

### 方式 D：Claude Code / Kimi 的 MCP 配置

在 `~/.claude/config.json`（或 Kimi 对应配置）中：

```json
{
  "mcpServers": {
    "agentapi": {
      "command": "agentapi",
      "args": ["mcp", "stdio"],
      "env": {
        "AGENTAPI_CONFIG": "~/.agentapi/config.yaml"
      }
    }
  }
}
```

---

## 12. TechMarkdown 接入方案

TechMarkdown 是 Swift macOS 应用，接入方式有两种：

### 方案 1：HTTP REST（改动最小）

在 Swift 中封装一个 `AgentAPIClient`：

```swift
final class AgentAPIClient {
    static let shared = AgentAPIClient()
    private let baseURL = URL(string: "http://127.0.0.1:8787")!

    func chat(model: String, messages: [[String: String]]) async throws -> String {
        let url = baseURL.appendingPathComponent("/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "stream": false
        ])

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // 解析 choices[0].message.content
        ...
    }
}
```

然后在 `AIAgent.swift` 中，把原来直接调用 OpenAI/Anthropic 的地方改成调用 `AgentAPIClient`。

优点：
- 不需要引入 MCP 依赖。
- 网关升级、模型列表更新、key 轮换对 TechMarkdown 完全透明。

### 方案 2：MCP Client（更 Agent-native）

TechMarkdown 内部启动 `agentapi mcp stdio` 子进程，通过 stdin/stdout 与 MCP server 通信。可使用 Swift 的 `Process` + `JSON-RPC` 封装。

优点：
- 复用统一的 tools 语义。
- 未来 Agent 切换工具更灵活。

> 建议 TechMarkdown 先用方案 1 验证，稳定后再评估方案 2。

---

## 13. 用量统计表结构（SQLite）

```sql
CREATE TABLE usage_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
  agent_id TEXT,              -- 调用方标识，如 "techmarkdown"
  provider TEXT,
  model TEXT,
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  total_tokens INTEGER,
  estimated_cost REAL,        -- 美元
  latency_ms INTEGER,
  status TEXT                 -- success / error
);
```

查询示例：

```bash
agentapi usage --model openai/gpt-4o --last 7d
```

---

## 14. 后续扩展建议

| 优先级 | 功能 | 说明 |
|--------|------|------|
| P0 | 基础 REST + MCP + OpenAI/Anthropic adapter | 先跑通 |
| P1 | Prompt Registry + 变量替换 | 沉淀常用 prompt |
| P1 | Usage SQLite + CLI 查询 | 成本透明 |
| P2 | 流式 SSE 统一输出 | 提升体验 |
| P2 | 模型能力标签 + 自动 fallback | 如 gpt-4o 不可用时切到 gpt-4o-mini |
| P3 | Web UI 管理后台 | 可视化 key、模型、用量 |
| P3 | 多用户/team 模式 | 远程部署时权限隔离 |

---

## 15. 开发里程碑

1. **MVP（1-2 天）**：
   - Node.js 项目骨架 + config.yaml 读取
   - OpenAI adapter + `/v1/chat/completions`
   - Anthropic adapter
   - 本地 `npm start` 可运行

2. **MCP 接入（1 天）**：
   - 实现 4 个核心 tools
   - Claude Code / Kimi 可调用

3. **TechMarkdown 对接（1 天）**：
   - Swift `AgentAPIClient`
   - 替换 `AIAgent.swift` 中直接模型调用

4. **增强（后续）**：
   - Usage tracker、Prompt registry、Web UI

---

## 16. 结论

AgentAPI Gateway 的核心价值：**一次配置，处处可用**。所有 Agent 都不再需要知道 DeepSeek、Claude、GPT、Gemini 的具体接口差异，只需调用网关暴露的 MCP tools 或标准 REST 接口。模型、key、提示词、用量统计全部在本地网关集中管理，新增模型或厂商时只需要改网关配置，Agent 代码零改动。

下一步建议：先搭建最小可运行版本（MVP），然后让 TechMarkdown 作为第一个测试客户端接入。
