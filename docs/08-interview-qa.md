# 面试问答集锦

## 一、项目介绍（1-2 分钟版本）

> TechMarkdown 是一款 macOS 原生 Markdown 编辑器，我在基础版之上扩展了 AI Agent 能力。核心功能包括：AI 问答侧边栏、对当前文档提问、修改建议并让用户确认后应用、本地文件引用、Skill 快捷任务、Tool Use（函数调用）和 MCP 扩展机制。
> 
> 技术上使用 SwiftUI + Swift Package Manager，参考了 PinSight 的多 Provider AI 配置模式，引入 OpenAI 兼容接口。我负责架构设计、核心模块实现、编译验证和文档整理。

## 二、高频问题

### Q1：为什么要做这个项目？

A：传统 Markdown 编辑器是静态的，写文档和查资料需要频繁切换窗口。我希望让编辑器成为「写作助手」——用户可以直接对文档提问、获得修改建议、引用本地资料，所有操作都在一个窗口内完成。

### Q2：AI Agent 和简单的 ChatGPT 网页版有什么区别？

A：Agent 不只是对话，而是能**感知环境、调用工具、执行动作**。在 TechMarkdown 中：

- 感知：读取当前文档和引用的本地文件。
- 工具：read_file、search_in_document、apply_markdown_edit 等。
- 执行：把 AI 建议转换成可确认的修改，用户同意后应用到文档。
- 扩展：通过 MCP 接入外部工具。

### Q3：你是怎么设计 Tool Use / Function Calling 的？

A：核心流程：

1. 定义 `ToolExecutable` 协议和 `ToolDefinition` 工具描述。
2. `ToolRegistry` 单例管理所有工具。
3. 请求 LLM 时传入 `tools` 参数（OpenAI function schema）。
4. LLM 返回 `tool_calls` 后，顺序执行每个工具。
5. 工具结果以 `tool` role message 回填历史。
6. 再次请求 LLM 获取自然语言总结。

### Q4：Skill 和 Tool 的关系是什么？

A：Tool 是底层能力（如读文件、改文档），Skill 是面向用户的任务模板（如润色、翻译、生成目录）。Skill 会组装 prompt 并限制可用工具，让用户不需要手写复杂指令。

### Q5：修改建议为什么要用户确认？

A：AI 修改文档是**高风险操作**，直接覆盖可能导致内容丢失或不符合预期。通过 `PendingEdit` + Diff 预览 + 确认/拒绝按钮，实现人类-in-the-loop，保证用户最终决策权。

### Q6：本地文件引用是怎么实现的？

A：用户在消息中写 `[[path]]` 或拖拽文件，`FileContextService` 解析路径、校验沙盒范围、读取内容，然后把文件内容拼接到上下文中发给 LLM。支持相对路径、绝对路径和 `~` 简写。

### Q7：如何处理超长文档？

A：当前版本做字符截断，保留开头和结尾。更优方案是 RAG：分块、向量化、按问题召回相关 chunk。这是后续优化方向。

### Q8：多 Provider 怎么兼容？

A：主要采用 OpenAI 兼容接口，豆包、通义千问都支持。Gemini 原生接口可以通过标记 `format` 单独适配。配置层抽象了 baseURL、model、apiKey，切换 Provider 只需改配置。

### Q9：API Key 怎么存储？

A：使用 macOS Keychain。配置对象只保存 account 标识，真正的 key 在保存时写入 Keychain，读取时取出。

### Q10：项目遇到什么困难？

A：主要有三个：

1. 环境没有完整 Xcode，改用 SPM + `swift build` 验证。
2. `AIAgent.configuration` 访问权限导致 UI 编译失败，改为 internal。
3. `applyPendingEdit` 参数类型不匹配，统一改为操作 `String`。

### Q11：如果继续迭代，你会做哪些改进？

A：

1. RAG：长文档语义检索。
2. 对话记忆持久化：SQLite 存储历史。
3. MCP stdio 完整支持：真正的 JSON-RPC 客户端。
4. Diff 算法优化：字符级 Diff。
5. 可观测性：Token 消耗、延迟、错误率监控。

## 三、技术深度问题

### Q12：Function Calling 的具体请求/响应格式？

A：请求体：

```json
{
  "model": "gpt-4o-mini",
  "messages": [...],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_file",
        "description": "...",
        "parameters": { "type": "object", "properties": {...}, "required": [...] }
      }
    }
  ],
  "stream": true
}
```

响应中的 tool_calls：

```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "tool_calls": [{
        "id": "call_xxx",
        "type": "function",
        "function": { "name": "read_file", "arguments": "{\"path\":\"doc.md\"}" }
      }]
    }
  }]
}
```

### Q13：你的架构里哪些是可扩展的？

A：

- `ToolExecutable` 协议：新增工具只需实现协议并注册。
- `SkillDefinition`：新增 Skill 只需定义配置。
- `MCPClientProtocol`：支持任意传输方式的 MCP Client。
- `AIProviderConfiguration`：新增 Provider 只需增加 preset。

### Q14：MCP 和你自己写的工具有什么区别？

A：内置工具是应用原生的，MCP 是外部协议。MCP 让第三方服务以标准化方式接入，不需要修改应用代码。我在应用层把 MCP 工具转换为 `ToolDefinition`，让 LLM 无感知调用。

### Q15：怎么保证 AI 不越权修改文档？

A：

1. `apply_markdown_edit` 工具不直接写文件，只生成 `PendingEdit`。
2. 用户必须点击确认才应用。
3. 应用后编辑器本身支持 Undo。
4. 文件读取受沙盒和路径校验限制。

## 四、行为面试问题

### Q16：你在项目中学到了什么？

A：

- SwiftUI 与 Combine 的响应式数据流设计。
- OpenAI function calling 的完整协议。
- 如何在受限环境中验证项目（SPM）。
- 人类-in-the-loop 对 AI 产品的重要性。

### Q17：如果再来一次，你会怎么做不同？

A：

- 更早做端到端流程验证，而不是先把所有模块写完再编译。
- 用依赖注入替代部分 `UserDefaults` 中转。
- 先写单元测试再写实现，减少返工。
