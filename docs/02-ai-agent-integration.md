# AI Agent 集成设计

## 1. 设计目标

将 TechMarkdown 从一个静态编辑器升级为**能够理解、建议并修改 Markdown 文档的 Agent**。核心能力包括：

- **上下文感知**：AI 始终知道当前文档内容。
- **多轮对话**：保留历史，支持追问。
- **本地文件引用**：通过 `@path` 或文件选择器引入外部上下文。
- **修改建议 + 确认**：直接修改必须经用户确认，避免误操作。
- **Skill 化**：常用任务封装为 Skill，降低使用门槛。

## 2. 核心模型

### 2.1 ChatMessage

```swift
struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var role: ChatRole          // system / user / assistant / tool
    var content: String
    var toolCalls: [ToolCall]?  // assistant 的工具调用请求
    var toolCallID: String?     // tool 角色的回执 ID
    var timestamp: Date
    var referencedFiles: [ReferencedFile]
}
```

role 包含 `tool` 是为了实现 OpenAI 的 function calling 多轮协议：

```
user -> assistant(tool_calls) -> tool(tool_call_id) -> assistant(final)
```

### 2.2 AIAgent

`AIAgent` 是协调器，持有：

- `messages: [ChatMessage]`：对话历史
- `referencedFiles: [ReferencedFile]`：用户引用的本地文件
- `pendingEdit: PendingEdit?`：待确认的修改
- `isProcessing`：请求状态

## 3. 对话流程

```swift
func sendMessage(_ text: String, documentText: String) async {
    // 1. 解析 @path 引用并自动加载文件
    let (cleanText, referencedPaths) = FileContextService.shared.extractFileReferences(from: text)
    for path in referencedPaths { await addReferencedFile(path: path) }
    
    // 2. 追加用户消息
    messages.append(ChatMessage(role: .user, content: cleanText))
    
    // 3. 执行对话轮次
    await performChatRound(documentText: documentText)
}
```

`performChatRound` 的工作细节：

```swift
private func performChatRound(documentText: String, preferredTools: [String] = []) async {
    // 同步当前文档到 UserDefaults，供 search_in_document 工具读取
    UserDefaults.standard.set(documentText, forKey: "techmarkdown.currentDocumentText")
    
    // 收集工具：内置 + MCP 发现
    var availableTools = ToolRegistry.shared.allDefinitions
    availableTools.append(contentsOf: mcpManager.discoveredTools)
    if !preferredTools.isEmpty {
        availableTools = availableTools.filter { preferredTools.contains($0.name) }
    }
    
    // 请求 LLM
    let response = try await AIService.shared.chat(...)
    messages.append(ChatMessage(role: .assistant, content: response.content, toolCalls: response.toolCalls))
    
    // 处理工具调用链
    if !response.toolCalls.isEmpty {
        for toolCall in response.toolCalls {
            let result = await ToolRegistry.shared.execute(toolCall: toolCall)
            messages.append(ChatMessage(role: .tool, content: result.output, toolCallID: result.toolCallID))
        }
        // 工具结果再次请求 LLM，获取最终自然语言回复
        let finalResponse = try await AIService.shared.chat(messages: messages, tools: [], ...)
        messages.append(ChatMessage(role: .assistant, content: finalResponse.content))
    }
}
```

## 4. System Prompt 设计

System Prompt 是 Agent 行为的核心约束：

```
你是 TechMarkdown Agent，一位精通 Markdown 文档处理与解读的 AI 助手。

工作原则：
1. 回答应简洁、准确、可操作。
2. 若用户要求修改文档，优先使用 apply_markdown_edit 工具。
3. 若用户引用本地文件，请结合文件内容回答。
4. 行内数学公式使用 $...$，独立公式使用 $$...$$。
5. 直接修改前必须让用户确认，除非用户明确说“直接修改”。

当前文档内容如下：
---
{documentText}
---

引用的本地文件：
[文件: /path/to/file]
{contentPreview}
```

**设计要点**：

- 明确 Agent 身份和能力边界。
- 把当前文档完整注入，确保回答基于事实。
- 注入引用文件内容，实现 RAG-like 上下文增强。
- 通过原则 5 保证安全性，避免未经允许直接覆盖用户文档。

## 5. 修改确认机制

### 5.1 为什么需要确认？

LLM 生成的修改可能不符合用户预期。直接覆盖会导致数据丢失风险。因此设计了「建议 → 差异预览 → 用户确认 → 应用」的流程。

### 5.2 PendingEdit 状态机

```swift
struct PendingEdit: Identifiable {
    let id = UUID()
    var originalText: String
    var suggestedText: String
    var reason: String
}
```

触发流程：

1. AI 调用 `apply_markdown_edit` 工具。
2. `ToolRegistry` 发送 `pendingMarkdownEdit` 通知。
3. `AIAgent` 接收通知，创建 `PendingEdit`。
4. `AISidebarView` 展示修改摘要和「查看差异 / 放弃 / 应用」按钮。
5. 用户点击「应用」→ `AIAgent.applyPendingEdit(to: &document.text)`。

### 5.3 差异预览

使用 `computeLineDiff`（LCS 行级 diff）计算增删行数，用户也可打开完整差异面板逐行查看。

## 6. Skill 机制

Skill 是对常见任务的封装，降低 prompt 工程门槛。

```swift
struct SkillDefinition {
    let id: String
    var name: String
    var description: String
    var icon: String
    var promptTemplate: String
    var suggestedTools: [String]
}
```

执行 Skill：

```swift
func runSkill(_ skill: SkillDefinition, documentText: String, extraInput: String = "") async {
    let prompt = skill.promptTemplate + "\n\n" + extraInput + documentText
    messages.append(ChatMessage(role: .user, content: "[Skill: \(skill.name)]\n\(prompt)"))
    await performChatRound(documentText: documentText, preferredTools: skill.suggestedTools)
}
```

内置 Skill：总结、润色、翻译、解释、生成目录。每个 Skill 可以限制可用工具（例如润色只给 `apply_markdown_edit`），避免 AI 调用不相关工具浪费 token。

## 7. 多服务商支持

```swift
enum AIProviderID: String, Codable, CaseIterable, Identifiable {
    case openAI
    case gemini
    case doubao
    case qwen
    case custom
}
```

每个 provider 提供：

- 显示名称
- 默认 baseURL
- 推荐模型列表
- 默认模型
- API Key 账户名

用户切换 provider 时，自动回填默认 baseURL 和 model。自定义 provider 允许任意 OpenAI 兼容服务。

## 8. 安全与隐私

- API Key 存储在 Keychain，不在内存中长期保留明文（仅在请求时使用）。
- 本地文件读取需要用户显式选择或 `@path` 输入，遵守 App Sandbox 的 `files.user-selected.read-write`。
- 网络请求仅用于调用大模型 API 和加载 CDN 资源。

## 9. 面试常见问题

**Q: 如何保证 AI 修改不会误删用户内容？**

A: 通过 `PendingEdit` + diff 预览 + 用户确认的三层机制。直接修改只有在用户点击「应用」后才会写入文档，且保留原始文本用于对比和撤销。

**Q: 对话历史过长如何处理？**

A: `AIProviderConfiguration.maxHistoryTurns` 控制传给 LLM 的历史轮数，避免 token 爆炸。超出部分保留在 UI 中但不再参与模型推理。

**Q: 如何实现本地文件作为上下文？**

A: 用户输入 `@~/Documents/note.md` 或点击附件选择文件，`FileContextService` 读取文件内容并注入 system prompt。这类似于 RAG 中的上下文注入，但没有走向量检索，而是直接读取完整文件（适合小文件）。
