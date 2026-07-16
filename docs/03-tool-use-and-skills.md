# Tool Use 与 Skill 框架

## 1. Tool Use 设计

### 1.1 核心协议

```swift
// Models/Tool.swift
protocol ToolExecutable: AnyObject {
    var definition: ToolDefinition { get }
    func execute(arguments: [String: Any]) async throws -> String
}
```

- `definition`：描述工具名称、功能、参数模式（OpenAI function schema）。
- `execute`：实际执行逻辑，返回字符串结果给 LLM。

### 1.2 ToolDefinition / ToolParameter

```swift
// Models/Tool.swift
struct ToolDefinition: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var description: String
    var parameters: [ToolParameter]
    var requiredParameters: [String]
    
    var openAISchema: [String: Any] { ... }
}

struct ToolParameter: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var type: String
    var description: String
    var `enum`: [String]?
    
    var schema: [String: Any] { ... }
}
```

`openAISchema` 生成 OpenAI function calling 所需的 JSON Schema：

```json
{
  "type": "function",
  "function": {
    "name": "read_file",
    "description": "读取本地文件的内容...",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "..." }
      },
      "required": ["path"]
    }
  }
}
```

### 1.3 ToolRegistry

`ToolRegistry` 是单例注册中心，负责：

- 注册内置工具
- 根据 `ToolCall` 分发执行
- 收集所有工具定义供 LLM 使用

```swift
// Services/ToolRegistry.swift
final class ToolRegistry {
    static let shared = ToolRegistry()
    private var tools: [String: ToolExecutable] = [:]
    
    var allDefinitions: [ToolDefinition] { ... }
    func register(_ tool: ToolExecutable) { ... }
    func execute(toolCall: ToolCall) async -> ToolResult { ... }
}
```

## 2. 内置工具

### 2.1 read_file

读取本地文件内容，支持 `~/` 简写。

```swift
// Services/ToolRegistry.swift
final class ReadFileTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "read_file",
        description: "读取本地文件的内容，支持 Markdown、文本、代码文件等。路径支持 ~/ 简写。",
        parameters: [
            ToolParameter(name: "path", type: "string", description: "文件的绝对路径或相对于用户主目录的路径")
        ],
        requiredParameters: ["path"]
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else { ... }
        return try await FileContextService.shared.readFile(at: path)
    }
}
```

### 2.2 list_directory

列出指定目录下的文件和文件夹。

### 2.3 search_in_document

在当前 Markdown 文档中搜索关键词，返回匹配行号与上下文。

**实现细节**：由于 `ToolRegistry` 是单例，不直接持有文档对象，通过 `UserDefaults` 中转当前文档内容。调用前 `AIAgent` 会同步 `documentText` 到 `UserDefaults`。

```swift
extension NotificationCenter {
    var currentDocumentText: String {
        UserDefaults.standard.string(forKey: "techmarkdown.currentDocumentText") ?? ""
    }
}
```

这是一种轻量级的跨组件状态共享方案，适合工具执行器与主界面解耦的场景。

### 2.4 apply_markdown_edit

将 AI 生成的完整 Markdown 文本作为修改建议，等待用户确认。

```swift
func execute(arguments: [String: Any]) async throws -> String {
    guard let markdown = arguments["markdown"] as? String else { return "缺少 markdown 参数" }
    let reason = arguments["reason"] as? String ?? "AI 建议的修改"
    
    NotificationCenter.default.post(
        name: .pendingMarkdownEdit,
        object: nil,
        userInfo: ["markdown": markdown, "reason": reason]
    )
    
    return "修改建议已生成，等待用户在侧边栏确认。"
}
```

## 3. 工具调用链

OpenAI function calling 支持模型一次性返回多个工具调用。TechMarkdown 的处理流程：

```
1. LLM 返回 assistant message + tool_calls[]
2. 将 assistant message 加入 history
3. 顺序执行每个 tool_call
4. 每个 tool 结果作为 tool role message 加入 history
5. 再次请求 LLM（不带 tools），获取最终自然语言回复
```

这种「请求 → 调用 → 回填 → 再请求」的模式是 function calling 的标准多轮协议，也是 ReAct 推理框架的简化实现。

## 4. Skill 框架

### 4.1 为什么需要 Skill？

- 降低用户使用门槛：不需要写复杂 prompt。
- 限制工具范围：例如「润色」只给 `apply_markdown_edit`，避免无关工具调用。
- 统一体验：常用任务有固定入口和图标。

### 4.2 Skill 定义

```swift
// Models/Skill.swift
struct SkillDefinition: Identifiable, Hashable {
    let id: String
    var name: String
    var description: String
    var icon: String
    var promptTemplate: String
    var suggestedTools: [String]
}

enum BuiltInSkill {
    static let summarize = SkillDefinition(...)
    static let polish = SkillDefinition(...)
    ...
    static let all: [SkillDefinition] = [...]
}
```

### 4.3 内置 Skill

| Skill | 功能 | 可用工具 |
|---|---|---|
| summarize | 总结文档 | 无 |
| polish | 润色优化 | apply_markdown_edit |
| translate | 中英互译 | apply_markdown_edit |
| explain | 解释概念/公式/代码 | 无 |
| generate_toc | 生成目录 | apply_markdown_edit |

### 4.4 执行 Skill

```swift
// Services/AIAgent.swift
func runSkill(_ skill: SkillDefinition, documentText: String, extraInput: String = "") async {
    let prompt = skill.promptTemplate + "\n\n" + (extraInput.isEmpty ? "" : "用户补充要求：\(extraInput)\n\n") + documentText
    messages.append(ChatMessage(role: .user, content: "[Skill: \(skill.name)]\n\(prompt)"))
    await performChatRound(documentText: documentText, preferredTools: skill.suggestedTools)
}
```

## 5. 如何新增一个工具

步骤：

1. 在 `Services/ToolRegistry.swift` 中创建新类实现 `ToolExecutable`。
2. 定义 `definition`（名称、描述、参数）。
3. 实现 `execute(arguments:)`。
4. 在 `registerBuiltInTools()` 中注册。

示例：添加一个读取剪贴板内容的工具。

```swift
final class ReadClipboardTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "read_clipboard",
        description: "读取系统剪贴板的文本内容",
        parameters: [],
        requiredParameters: []
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        NSPasteboard.general.string(forType: .string) ?? "剪贴板没有文本内容"
    }
}
```

注册：

```swift
private func registerBuiltInTools() {
    register(ReadFileTool())
    register(ListDirectoryTool())
    register(SearchInDocumentTool())
    register(ApplyMarkdownEditTool())
    register(ReadClipboardTool())  // 新增
}
```

## 6. 如何新增一个 Skill

步骤：

1. 在 `Models/Skill.swift` 的 `BuiltInSkill` 中定义新的 `SkillDefinition`。
2. 将其加入 `BuiltInSkill.all` 数组。

示例：添加「提取关键词」Skill。

```swift
static let extractKeywords = SkillDefinition(
    id: "extract_keywords",
    name: "提取关键词",
    description: "从文档中提取核心关键词并生成标签",
    icon: "tag",
    promptTemplate: "请从以下 Markdown 文档中提取 5-10 个核心关键词，并用 #标签 形式列出。",
    suggestedTools: []
)
```

## 7. 面试常见问题

**Q: Function Calling 和普通 prompt 有什么区别？**

A: Function Calling 让模型输出结构化函数调用（JSON），由程序执行后将结果回填，适合需要精确控制、与外部系统交互的场景。普通 prompt 只能得到文本，难以保证格式稳定。

**Q: 工具调用失败如何处理？**

A: `ToolRegistry.execute` 会捕获异常并返回 `isError = true` 的 `ToolResult`，LLM 看到错误信息后可以自适应调整（例如换一个文件路径）。

**Q: 如何防止工具被滥用？**

A: 通过 `suggestedTools` 限制 Skill 可用工具范围；`apply_markdown_edit` 不直接修改文档，而是生成 `PendingEdit` 等待确认；文件读取需要用户显式授权或输入路径。
