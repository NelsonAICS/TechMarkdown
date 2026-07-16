# 上下文管理与本地文件引用

## 1. 上下文管理目标

TechMarkdown 的核心场景是「对当前 Markdown 文档提问」，因此上下文需要包含：

1. **当前文档全文**：作为 primary context。
2. **用户消息历史**：多轮对话记忆。
3. **引用的本地文件**：通过 `@path` 或拖拽注入。
4. **Skill 提示模板**：固定任务的前置指令。
5. **工具调用结果**：Function calling 的往返信息。

## 2. 上下文组装策略

`AIService.chat` 会组装 OpenAI 请求体：

```swift
// Services/AIService.swift
var requestMessages: [[String: Any]] = [
    ["role": "system", "content": systemPrompt(documentText: documentText, referencedFiles: referencedFiles)]
]

for msg in messages.suffix(configuration.maxHistoryTurns) {
    var messageDict: [String: Any] = [
        "role": msg.role.rawValue,
        "content": msg.content
    ]
    if let toolCalls = msg.toolCalls, !toolCalls.isEmpty { ... }
    if let toolCallID = msg.toolCallID { ... }
    requestMessages.append(messageDict)
}
```

**关键设计**：当前文档和引用文件放在 system prompt 中，历史消息做截断控制，避免 token 爆炸。

## 3. Token 控制

对话历史通过 `maxHistoryTurns` 限制：

```swift
// Models/AIProvider.swift
struct AIProviderConfiguration: Codable, Hashable {
    ...
    var maxHistoryTurns: Int = 10
}
```

```swift
// Services/AIService.swift
for msg in messages.suffix(configuration.maxHistoryTurns) { ... }
```

当前版本保留最近 N 轮完整消息。超出部分仍保留在 UI 中，但不再传给模型。

## 4. 本地文件引用

### 4.1 引用语法

用户可以在消息中引用本地文件：

```
请帮我润色 @(~/notes/draft.md) 的第三段
```

也支持直接 `@path`（无括号）或拖拽文件到输入框。

### 4.2 FileContextService

```swift
// Services/FileContextService.swift
final class FileContextService {
    static let shared = FileContextService()
    
    func extractFileReferences(from text: String) -> (cleanText: String, paths: [String]) { ... }
    func readFile(at path: String, maxLength: Int = 100_000) async throws -> String { ... }
    func listDirectory(at path: String, maxDepth: Int = 1) async throws -> String { ... }
}
```

### 4.3 路径解析规则

1. 展开 `~` 为 home directory。
2. 如果是绝对路径，直接使用。
3. 相对路径基于 home directory 解析（当前版本简化实现）。
4. 检查文件存在和可读性。

```swift
let expandedPath = NSString(string: path).expandingTildeInPath
let url: URL
if expandedPath.hasPrefix("/") {
    url = URL(fileURLWithPath: expandedPath)
} else {
    url = URL(fileURLWithPath: expandedPath, relativeTo: FileManager.default.homeDirectoryForCurrentUser)
}
```

### 4.4 安全限制

- 文件读取需要用户显式选择或输入路径。
- 遵守 macOS App Sandbox 的 `files.user-selected.read-write`。
- 网络请求仅用于调用大模型 API。

## 5. 上下文压缩

当上下文超过 token 限制时，后续会实现：

- **对话摘要**：保留早期对话摘要，只保留最近 N 轮完整消息。
- **语义分块**：对长文档按标题切分，只召回相关 chunk。
- **关键词过滤**：先提取用户问题关键词，只加载相关段落。

当前版本使用 `maxHistoryTurns` 截断，已能满足大部分面试演示需求。

## 6. 面试常见问题

**Q: 如何处理超长文档？**

A: 当前方案是历史截断 + 完整文档放在 system prompt。更优的方案是 RAG：将文档分块、向量化，按问题召回相关 chunk。

**Q: 本地文件引用如何避免路径遍历攻击？**

A: 展开符号链接、检查文件存在和可读性、遵守沙盒范围、避免访问超出用户选择范围的文件。

**Q: 多轮对话如何保证上下文连贯？**

A: `AIAgent` 维护 `messages` 数组，每轮对话追加到历史。system prompt 持续存在，确保助手角色一致。
