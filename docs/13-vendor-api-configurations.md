# 模型厂商 API 配置规范

> 本文档是 TechMarkdown 与 TokenAPIGate 中各模型厂商预设的**唯一事实来源**。后续收到新的官方 API 文档后，应同步更新本文档，并据此调整代码中的 preset/model/baseURL 配置。

## 维护约定

- **已确认**：已根据官方文档逐条核对。
- **待校准**：当前为经验值或历史值，需拿到官方文档后重新核对。
- **已弃用**：官方已宣布下线或更名的模型/接口，仅作兼容说明，不在预设中默认展示。

配置项统一含义：

| 字段 | 说明 |
|---|---|
| `provider_id` | 在 TokenAPIGate 网关内的唯一标识，也是 TechMarkdown 选择 TokenAPIGate 时模型名的前缀 |
| `name` | 展示名称 |
| `base_url` | 厂商 OpenAI 兼容协议的 Base URL（不含 `/chat/completions`） |
| `chat_completions_url` | 直接调用的完整 Chat Completions 地址 |
| `api_key_env` | 建议的 API Key 环境变量名 / Keychain Account 名 |
| `models` | 当前推荐模型列表 |
| `deprecated_models` | 已弃用但仍可兼容的模型 |
| `protocol` | 适配协议，如 `openai-compatible`、`anthropic`、`gemini` |
| `official_docs` | 官方文档地址 |

---

## DeepSeek

- **状态**：已确认（依据 [DeepSeek API 文档](https://api-docs.deepseek.com/zh-cn/)）
- **协议**：OpenAI 兼容
- **provider_id**：`deepseek`
- **base_url**：`https://api.deepseek.com`
- **chat_completions_url**：`https://api.deepseek.com/chat/completions`
- **anthropic_url**（如需要）：`https://api.deepseek.com/anthropic`
- **api_key_env**：`DEEPSEEK_API_KEY`
- **鉴权头**：`Authorization: Bearer ${DEEPSEEK_API_KEY}`

### 推荐模型

| 模型 ID | 说明 |
|---|---|
| `deepseek-v4-flash` | 轻量高速模型 |
| `deepseek-v4-pro` | 旗舰模型，支持思考模式 |

### 已弃用模型

| 模型 ID | 说明 | 弃用时间 |
|---|---|---|
| `deepseek-chat` | 对应 `deepseek-v4-flash` 的非思考模式 | 2026/07/24 |
| `deepseek-reasoner` | 对应 `deepseek-v4-flash` 的思考模式 | 2026/07/24 |

### 特殊参数

- 开启思考模式：`"thinking": {"type": "enabled"}`
- 推理强度：`"reasoning_effort": "high"`（可选值参考官方文档）
- 流式：`"stream": true`

### 代码中对应位置

- **TechMarkdown**：`TechMarkdown/Models/AIProvider.swift` → `AIProviderID.deepseek`
- **TokenAPIGate**：`TokenAPIGate/src-tauri/src/providers.rs` → `default_presets()` 中 `id == "deepseek"` 的 Provider

---

## OpenAI

- **状态**：待校准
- **协议**：OpenAI 原生
- **provider_id**：`openai`
- **chat_completions_url**：`https://api.openai.com/v1/chat/completions`
- **api_key_env**：`OPENAI_API_KEY`
- **当前预设模型**：`gpt-4o-mini`, `gpt-4o`, `gpt-5.4-mini`, `gpt-5.4`
- **官方文档**：https://platform.openai.com/docs

---

## Google Gemini

- **状态**：待校准
- **协议**：OpenAI 兼容
- **provider_id**：`gemini`
- **chat_completions_url**：`https://generativelanguage.googleapis.com/v1beta/openai/chat/completions`
- **api_key_env**：`GEMINI_API_KEY`
- **当前预设模型**：`gemini-2.5-flash`, `gemini-2.5-pro`, `gemini-3-flash-preview`
- **官方文档**：https://ai.google.dev/gemini-api/docs

---

## 火山方舟 / 豆包（标准 API）

- **状态**：已确认（依据 [火山方舟快速入门](https://www.volcengine.com/docs/82379/1399008?lang=zh)、[文本生成](https://www.volcengine.com/docs/82379/1399009?lang=zh) 与 [接入三方工具](https://www.volcengine.com/docs/82379/2160841)）
- **协议**：OpenAI 兼容
- **provider_id**：`doubao`
- **base_url**：`https://ark.cn-beijing.volces.com/api/v3`
- **chat_completions_url**：`https://ark.cn-beijing.volces.com/api/v3/chat/completions`
- **api_key_env**：`ARK_API_KEY`
- **鉴权头**：`Authorization: Bearer ${ARK_API_KEY}`

### 推荐模型（示例）

> 方舟模型 ID 会随版本迭代，实际使用时应从控制台「API 接入」或「模型列表」中复制最新 Model ID。

| 模型 ID | 说明 |
|---|---|
| `doubao-seed-1-6-251015` | Doubao Seed 1.6（官方快速入门示例） |
| `doubao-seed-1-6-250615` | Doubao Seed 1.6 另一版本 |

### 特殊参数

- 关闭深度思考：`"thinking": {"type": "disabled"}`
- 开启深度思考：`"thinking": {"type": "enabled"}`
- 流式：`"stream": true`

### 代码中对应位置

- **TechMarkdown**：`TechMarkdown/Models/AIProvider.swift` → `AIProviderID.doubao`
- **TokenAPIGate**：`TokenAPIGate/src-tauri/src/providers.rs` → `default_presets()` 中 `id == "doubao"` 的 Provider

---

## 火山方舟 Coding Plan

- **状态**：已确认（依据 [快速开始--火山方舟](https://www.volcengine.com/docs/82379/1928261) 与 [接入三方工具--火山方舟](https://www.volcengine.com/docs/82379/2160841)）
- **协议**：OpenAI 兼容（推荐）/ Anthropic 兼容（面向 Claude Code 等工具）
- **provider_id**：`ark-coding`
- **api_key_env**：`ARK_API_KEY`

### OpenAI 兼容接入（推荐用于 TokenAPIGate）

| 配置项 | 值 |
|---|---|
| `base_url` | `https://ark.cn-beijing.volces.com/api/coding/v3` |
| `chat_completions_url` | `https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions` |
| 鉴权头 | `Authorization: Bearer ${ARK_API_KEY}` |

### Anthropic 兼容接入（面向 Claude Code）

| 配置项 | 值 |
|---|---|
| `base_url` | `https://ark.cn-beijing.volces.com/api/coding` |
| `messages_url` | `https://ark.cn-beijing.volces.com/api/coding/v1/messages` |
| 鉴权头 | `x-api-key: ${ARK_API_KEY}`（Anthropic SDK 风格） |

> **注意**：TokenAPIGate 已同时支持 OpenAI Chat Completions 与 Anthropic Messages。Coding Plan 两种协议均可使用：
> - OpenAI 协议：选择 `ark-coding` provider，模型如 `ark-coding/ark-code-latest`
> - Anthropic 协议：选择 `ark-coding-anthropic` provider，模型如 `ark-coding-anthropic/ark-code-latest`
>
> 截图中的 Claude Code 配置对应 Anthropic 协议，可直接映射到 `ark-coding-anthropic`。

### 重要避坑

- **不要**使用 `https://ark.cn-beijing.volces.com/api/v3` 调用 Coding Plan 模型，该地址不会消耗 Coding Plan 额度，会额外按量计费。
- 切换模型既可以在工具配置里写死 `model`，也可以在控制台切换并保留 `ark-code-latest`。

### 推荐模型

| 模型 ID | 说明 |
|---|---|
| `ark-code-latest` | 控制台切换模型时使用 |
| `doubao-seed-2.0-code` | 代码场景 |
| `doubao-seed-2.0-pro` | 复杂推理 |
| `doubao-seed-2.0-lite` | 轻量快速 |
| `doubao-seed-code` | 代码专用 |
| `minimax-m2.7` | MiniMax 代码模型 |
| `minimax-m3` | MiniMax 通用模型 |
| `glm-5.2` / `glm-latest` | 智谱 GLM 模型 |
| `deepseek-v4-flash` | DeepSeek 轻量模型 |
| `deepseek-v4-pro` | DeepSeek 旗舰模型 |
| `kimi-k2.6` | Kimi K2.6 |
| `kimi-k2.7-code` | Kimi 代码模型 |

### 代码中对应位置

- **TechMarkdown**：`TechMarkdown/Models/AIProvider.swift` → `AIProviderID.arkCoding`
- **TokenAPIGate**：`TokenAPIGate/src-tauri/src/providers.rs` → `default_presets()` 中 `id == "ark-coding"` 的 Provider

---

## 通义千问

- **状态**：待校准
- **协议**：OpenAI 兼容
- **provider_id**：`qwen`
- **chat_completions_url**：`https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`
- **api_key_env**：`DASHSCOPE_API_KEY`
- **当前预设模型**：`qwen-plus-latest`, `qwen-turbo-latest`, `qwen3-vl-plus`
- **官方文档**：https://help.aliyun.com/zh/dashscope/

---

## TokenAPIGate（本地网关）

- **状态**：项目自定义
- **协议**：OpenAI 兼容
- **provider_id**：`tokenAPIGate`
- **chat_completions_url**：`http://127.0.0.1:8686/v1/chat/completions`
- **api_key_env**：`TOKENAPIGATE_KEY`（可选，网关本地鉴权时使用）
- **模型**：由网关内已启用 Provider 决定，格式为 `providerId/modelId`，例如 `deepseek/deepseek-v4-pro`
- **说明**：API Key 由各 Provider 在网关内集中管理，TechMarkdown 侧通常留空。

---

## TokenAPIGate 内置其他 Provider（待按官方文档校准）

| Provider | provider_id | 当前 base_url | 状态 |
|---|---|---|---|
| Anthropic | `anthropic` | `https://api.anthropic.com` | 待校准 |
| Azure OpenAI | `azure-openai` | `https://your-resource.openai.azure.com/openai/deployments` | 待校准 |
| Moonshot | `moonshot` | `https://api.moonshot.cn/v1` | 待校准 |
| 火山方舟 / 豆包 | `doubao` | `https://ark.cn-beijing.volces.com/api/v3` | 已确认 |
| 火山方舟 Coding Plan | `ark-coding` | `https://ark.cn-beijing.volces.com/api/coding/v3` | 已确认 |
| 火山方舟 Coding Plan (Anthropic) | `ark-coding-anthropic` | `https://ark.cn-beijing.volces.com/api/coding` | 已确认 |
| Qwen | `qwen` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | 待校准 |
| SiliconFlow | `siliconflow` | `https://api.siliconflow.cn/v1` | 待校准 |
| Zhipu | `zhipu` | `https://open.bigmodel.cn/api/paas/v4` | 待校准 |
| MiniMax | `minimax` | `https://api.minimaxi.chat/v1` | 待校准 |

---

## 更新记录

| 日期 | 更新内容 |
|---|---|
| 2026-06-15 | 根据 DeepSeek 官方文档确认 DeepSeek 的 base_url、接口、推荐模型与弃用模型 |
| 2026-06-15 | 根据火山方舟官方文档确认标准 API、Coding Plan 的 OpenAI/Anthropic 端点、模型列表与计费注意事项 |
