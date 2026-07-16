# 12. Agent 意图识别（Intent Recognition）

> 目标：让 AI Agent 在收到用户消息时，先判断用户到底想做什么，再决定调用哪些工具、走哪条技能路由，从而减少“该查项目时去联网”“该编辑文档时只回复不调用工具”等错误。

---

## 1. 为什么需要意图识别

在 TechMarkdown 中，Agent 同时掌握了多种能力：

- 编辑当前 Markdown 文档 (`apply_markdown_edit`)
- 检索项目文档 (`query_project_documents`)
- 读取项目文件 (`read_project_file`)
- 把项目文件加入上下文 (`add_project_file_to_context`)
- 联网搜索 (`web_search` / `web_read`)
- 查询/记录用户记忆 (`query_user_memory` / `record_memory`)
- 普通闲聊/问答

如果把这些工具全部一次性丢给大模型，让模型自己决定，常见问题是：

1. **选择困难**：工具太多，模型容易选错或反复调用不相关工具。
2. **成本浪费**：明明只想查项目文档，却额外走了 web_search。
3. **上下文干扰**：系统提示里同时塞了“编辑规则”“项目检索规则”，模型容易混淆。
4. **多轮漂移**：上一轮是文档编辑，下一轮用户问“帮我查一下相关资料”，模型仍继续调用编辑工具。

意图识别就是在一开始就回答：**“用户这条消息的核心诉求是什么？”** 然后据此优化工具排序、补充提示、甚至走不同的 Skill 流程。

---

## 2. 主流技术路线

### 2.1 基于规则的快速路由

用关键词、正则、模板匹配直接判定意图。

- **优点**：零成本、延迟低、可解释、对常见意图非常稳定。
- **缺点**：覆盖率低，容易被同义词、口语化表达绕过。
- **适用**：开场白、明确动词（“记住”“联网搜索”）、高频场景。

示例规则：

```swift
if text.contains("记住") { return .recordMemory }
if text.contains("联网") || text.contains("网上搜索") { return .webSearch }
```

### 2.2 Prompt-based Few-shot 分类

把意图类别和若干示例写进 prompt，让 LLM 输出结构化 JSON。

- **优点**：无需训练数据，上线快，可随提示迭代。
- **缺点**：每次分类都要调模型，增加一次 RTT；小模型可能不遵循 JSON 格式。
- **适用**：规则覆盖不到的模糊表达、长尾意图。

示例 prompt 片段：

```text
可选意图：
- query_project_documents: 在项目文档中检索主题
- read_project_file: 读取项目内某个具体文件
- edit_document: 修改当前 Markdown 文档
- web_search: 联网搜索
- chat: 普通闲聊

用户消息："帮我看看项目里有没有关于 MCP 的文档"
输出 JSON：{"intent": "query_project_documents", "confidence": 0.92}
```

### 2.3 Function Calling / Tool Router

把“意图选择”本身也定义成一个工具，让 LLM 调用 `classify_intent` 函数。

- **优点**：与后续工具调用同构，便于多步推理。
- **缺点**：仍然依赖模型函数调用能力；部分本地/轻量模型不支持。

### 2.4 Embedding / 向量相似度

预先将每个意图的“典型问法”向量化。用户消息也embedding后，与意图向量做相似度匹配。

- **优点**：不怕同义词改写，可自动扩展例句。
- **缺点**：需要 embedding 模型和向量存储；新增意图要维护例句库。
- **适用**：意图库稳定、查询量大、对延迟不敏感的场景。

### 2.5 轻量分类器（微调或小模型）

用 BERT / DistilBERT 等小型模型在标注数据上训练一个分类器。

- **优点**：延迟低、成本低、准确率高。
- **缺点**：需要标注数据；新增意图要重新训练/部署。
- **适用**：产品成熟、意图边界清晰、调用量巨大的场景。

### 2.6 Self-critique / Guardrails

让模型先给出意图，再让另一个轻量 prompt 检查是否合理，或要求模型给出置信度，低于阈值时 fallback 到通用对话。

- **优点**：降低误判伤害；可拦截异常工具调用。
- **缺点**：增加调用次数和延迟。

---

## 3. TechMarkdown 的选型与实现

本项目采用 **“规则启发 + LLM Few-shot 分类”的混合方案**，并辅以 **工具优先级排序**，原因如下：

1. **规则优先**：常见意图（“记住”“联网搜索”“读取文件”）用词明确，规则即可覆盖，避免每次都调模型。
2. **LLM 兜底**：规则未命中时，用一次轻量 LLM 调用做结构化分类。
3. **不强制屏蔽工具**：分类结果只影响工具排序，不删除其他工具。这样即使分类错误，模型仍有机会自我纠正，降低误判成本。
4. **置信度阈值**：LLM 置信度低于 0.6 时，视为普通对话，不调整工具排序。

### 3.1 意图分类表

| 意图 | 说明 | 优先工具 |
|---|---|---|
| `chat` | 普通对话、问候、无需工具 | 无 |
| `queryProjectDocs` | 在项目文档/代码中检索 | `query_project_documents`, `list_project_files`, `read_project_file` |
| `readProjectFile` | 读取项目内某个具体文件 | `read_project_file`, `list_project_files` |
| `addProjectFileToContext` | 把项目文件加入当前对话上下文 | `add_project_file_to_context`, `read_project_file` |
| `editDocument` | 修改当前 Markdown 文档 | `apply_markdown_edit`, `search_in_document` |
| `webSearch` | 联网搜索 | `web_search`, `web_read` |
| `queryMemory` | 查询用户偏好/历史文件 | `query_user_memory`, `search_file_index` |
| `recordMemory` | 记录用户偏好 | `record_memory` |
| `unknown` | 无法确定 | 无 |

### 3.2 分类流程

```text
用户输入
   │
   ▼
规则启发 ──命中──▶ 直接返回意图（高置信度）
   │
   未命中
   ▼
LLM Few-shot 分类 ──▶ JSON：intent / confidence / reason
   │
   ▼
根据置信度决定是否调整工具排序
```

### 3.3 工具排序策略

- 如果意图置信度 ≥ 0.6，把 `preferredToolNames` 对应的工具排在最前面。
- 其余工具保留，但排在后面。
- Skill 模式（`restrictTools = true`）下仍然严格限制在 Skill 建议的工具集合内，保证 Skill 行为可控。

这样模型第一眼看到的是最相关的工具，但不会被完全锁死。

---

## 4. 代码集成

### 4.1 核心文件

- `TechMarkdown/Services/IntentRecognitionService.swift`：意图分类服务。
- `TechMarkdown/Services/AIAgent.swift`：在 `performSendMessage` 中调用分类，并传入 `preferredTools`。
- `TechMarkdown/Services/ToolRegistry.swift`：工具定义和可用工具列表。

### 4.2 关键调用点

在 `AIAgent.performSendMessage` 中：

```swift
let intent = await IntentRecognitionService.shared.classify(
    text: cleanText,
    documentText: documentText,
    availableTools: ToolRegistry.shared.allDefinitions + MCPManager.shared.discoveredTools,
    configuration: configuration,
    apiKey: apiKey
)
self.lastIntentClassification = intent
let preferredTools = intent.confidence >= 0.6 ? intent.preferredTools : []

await performChatRound(
    documentText: documentText,
    preferredTools: preferredTools,
    restrictTools: false,
    selectedSnippets: selectedSnippets
)
```

### 4.3 提示增强

分类 prompt 中给出：

- 所有可选意图及说明。
- 当前可用工具名称和描述。
- 当前文档长度（辅助判断是否是“编辑当前文档”意图）。
- Few-shot JSON 输出样例。
- 明确的规则（闲聊用 `chat`、项目检索用 `query_project_documents` 等）。

通过 `temperature = 0.0` 让分类结果更稳定。

---

## 5. 评估与优化

### 5.1 离线评估

可以收集一组典型用户问句，标注正确意图，计算：

- **准确率（Accuracy）**：分类正确的比例。
- **Top-1 工具命中率**：分类结果对应的优先工具是否被模型真正调用。
- **误判代价**：错误分类是否导致明显的用户体验下降。

示例评估集：

| 用户消息 | 期望意图 |
|---|---|
| 记住我喜欢用简体中文 | `recordMemory` |
| 帮我查一下项目里有没有 MCP 设计文档 | `queryProjectDocs` |
| 打开 /Users/xxx/project/README.md | `readProjectFile` |
| 把刚才那个文件加进上下文 | `addProjectFileToContext` |
| 把这段翻译成英文 | `editDocument` |
| 网上搜一下 Swift 6 新特性 | `webSearch` |
| 你好 | `chat` |

### 5.2 在线指标

- 每次分类的 `intent` / `confidence` / `reason` 可记录到日志或记忆中。
- 观察模型实际调用的工具与分类意图是否一致。
- 用户对结果的满意度（如是否重复追问、是否手动触发工具）。

### 5.3 迭代方向

1. **扩充规则**：根据线上错误 case 增加关键词和同义表达。
2. **维护 Few-shot 示例**：把典型 bad case 加入分类 prompt。
3. **Embedding 路由**：当意图库稳定后，用本地 embedding 模型（如 `sentence-transformers` 或 Apple `NaturalLanguage`）替换 LLM 分类，降低延迟和成本。
4. **用户反馈闭环**：允许用户点击“这不是我想要的”来纠正意图，并记录到记忆系统。
5. **多轮意图继承**：结合对话历史，避免每轮都重新分类。例如上一轮是项目检索，本轮“再查一下相关实现”应继续走 `queryProjectDocs`。

---

## 6. 后续可落地的高级能力

### 6.1 多轮意图一致性

在 `AIAgent` 中维护一个 `conversationIntent` 状态：

- 如果新一轮分类结果与上一轮一致且置信度高，可直接复用，减少 LLM 调用。
- 如果用户输入是代词（“它”“这个”“再查一下”），用上一轮的意图补全。

### 6.2 意图驱动的 Skill 路由

把意图映射到内置 Skill：

- `editDocument` → 触发 `polish` / `translate` / `toc` Skill。
- `queryProjectDocs` → 触发 `documentRetrieval` Skill。
- `webSearch` → 触发 `webResearch` Skill。

这样 Agent 不仅是“工具选择”，而是“工作流选择”。

### 6.3 Guardrails

在工具执行前加入一层校验：

- 如果模型想调用 `apply_markdown_edit`，但分类结果是 `chat` 且置信度很高，提示用户确认。
- 如果模型想读取 `~/.ssh` 等敏感路径，拒绝执行。

---

## 7. 小结

TechMarkdown 的意图识别采用 **规则 + LLM Few-shot + 工具优先级排序** 的轻量混合架构：

- **快路径**：规则命中时零模型调用。
- **慢路径**：规则未命中时 LLM 输出结构化 JSON。
- **低风险**：只排序不屏蔽，分类错误不会导致功能完全不可用。
- **可扩展**：后续可逐步加入 embedding 路由、多轮一致性、Skill 路由等高级能力。

这套机制直接提升了 Agent 的工具选择准确率和响应效率，是后续多 Agent / Skill 编排的基础。
