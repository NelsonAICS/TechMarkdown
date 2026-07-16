# AG-UI 协议：AI 与 UI 之间的标准化事件流

> **适用读者**：前端/客户端开发者、AI Agent 架构师、产品经理、技术面试官。
> 
> **目标**：用一篇文章讲清楚 AG-UI（Agent–User Interaction Protocol）是什么、为什么需要它、怎么用，以及 TechMarkdown 中的真实落地方式。

---

## 1. 什么是 AG-UI？

**AG-UI** 是一个开放的、事件驱动的、双向的 Agent–User Interaction 协议。它规范了 **AI Agent 运行时** 与 **用户界面（UI）** 之间的通信方式：

- Agent 不直接操作 UI；
- UI 也不直接调用 Agent 内部函数；
- 两者之间通过一组**标准化事件**进行交互。

这些事件包括：

- 运行开始/结束
- 文本消息流式片段
- 工具调用生命周期
- 推理过程
- 状态快照与增量
- 自定义业务事件

> 可以把 AG-UI 理解为 AI Agent 世界的 "WebSocket / Server-Sent Events"：它不是模型推理协议，而是**模型输出如何被 UI 消费**的协议。

---

## 2. 为什么需要 AG-UI？

在传统的 LLM 客户端中，UI 通常这样工作：

```
用户输入 → 等待整个响应 → 一次性显示
```

这带来几个问题：

| 问题 | 说明 |
|------|------|
| **黑盒体验** | 用户不知道 AI 是在思考、调工具还是已出错 |
| **无法流式展示** | 长回复必须等全部生成完，体验差 |
| **工具调用不可见** | 调用 read_file / apply_edit 等工具时用户无感知 |
| **状态不同步** | AI 修改了文档后，UI 不知道何时刷新、如何回滚 |
| **多端复用难** | Web、iOS、Android、桌面需要各自适配模型输出格式 |

AG-UI 解决这些问题的核心思路是：**把 Agent 的内部活动，拆成可观察、可订阅、可重放的事件流。**

---

## 3. AG-UI 的协议架构

```
┌─────────────────────────────────────────────────────┐
│                     UI 层                            │
│  (SwiftUI / React / Web / 桌面 ...)                 │
└──────────────────┬──────────────────────────────────┘
                   │ 订阅 AGUIEvent 流
                   ▼
┌─────────────────────────────────────────────────────┐
│              AG-UI Event Bus / Stream               │
│   RUN_STARTED / TEXT_MESSAGE_CONTENT / TOOL_CALL_*  │
└──────────────────┬──────────────────────────────────┘
                   │ 消费并转发事件
                   ▼
┌─────────────────────────────────────────────────────┐
│                   Agent 运行时                       │
│  (对话管理 / 工具调用 / Skill / MCP / 状态机)        │
└──────────────────┬──────────────────────────────────┘
                   │ 发起 LLM 请求
                   ▼
┌─────────────────────────────────────────────────────┐
│              LLM Provider (OpenAI 兼容)             │
└─────────────────────────────────────────────────────┘
```

TechMarkdown 中的对应关系：

| 协议层 | TechMarkdown 实现 |
|--------|-------------------|
| UI 层 | `AISidebarView`、`AGUIEventLogView` |
| 事件总线 | `AGUIEventBus` |
| Agent 运行时 | `AIAgent` |
| LLM  Provider | `AIService`（OpenAI 兼容） |

---

## 4. 核心事件类型

AG-UI 事件统一由 `AGUIEvent` 结构表示：

```swift
struct AGUIEvent {
    let type: AGUIEventType
    let threadId: String?
    let runId: String?
    let parentRunId: String?
    let messageId: String?
    let toolCallId: String?
    let payload: AGUIEventPayload
    let timestamp: Date
}
```

### 4.1 生命周期事件

| 事件 | 含义 |
|------|------|
| `RUN_STARTED` | 一次 Agent Run 开始 |
| `RUN_FINISHED` | 一次 Agent Run 正常结束 |
| `RUN_ERROR` | 运行出错 |
| `STEP_STARTED` / `STEP_FINISHED` | 某个阶段开始/结束 |

### 4.2 文本消息事件

| 事件 | 含义 |
|------|------|
| `TEXT_MESSAGE_START` | 开始生成一条文本消息 |
| `TEXT_MESSAGE_CONTENT` | 文本消息的一个流式片段 |
| `TEXT_MESSAGE_END` | 文本消息生成完成 |

### 4.3 工具调用事件

| 事件 | 含义 |
|------|------|
| `TOOL_CALL_START` | 开始调用某个工具 |
| `TOOL_CALL_ARGS` | 工具参数流式增量 |
| `TOOL_CALL_END` | 工具参数接收完毕 |
| `TOOL_CALL_RESULT` | 工具执行结果 |

### 4.4 推理事件

| 事件 | 含义 |
|------|------|
| `REASONING_MESSAGE_CONTENT` | 模型推理/思考内容的增量 |

> 部分模型（如 DeepSeek-R1、Kimi k1.5、o1）会输出推理链，AG-UI 通过这类事件让 UI 可以展示 "AI 正在思考"。

### 4.5 状态管理事件

| 事件 | 含义 |
|------|------|
| `STATE_SNAPSHOT` | 完整状态快照 |
| `STATE_DELTA` | 状态增量（基于 JSON Patch） |
| `MESSAGES_SNAPSHOT` | 消息列表快照 |

---

## 5. TechMarkdown 中的 AG-UI 实现

### 5.1 事件总线

```swift
final class AGUIEventBus {
    private(set) var events: [AGUIEvent] = []
    private let subject = PassthroughSubject<AGUIEvent, Never>()
    
    func startRun(threadId: String, runId: String, parentRunId: String? = nil)
    func finishRun()
    func error(_ message: String, code: String? = nil)
    func emit(_ type: AGUIEventType, ...)
    func relay(_ event: AGUIEvent)
}
```

`AIAgent` 持有 `eventBus`，每个 Run 的生命周期都会通过它发出事件。

### 5.2 从 OpenAI SSE 到 AG-UI 事件

`AIService.chatStream(...)` 将 LLM 返回的 Server-Sent Events 解析为 `AsyncThrowingStream<AGUIEvent, Error>`：

```swift
for try await event in stream {
    // event.type 可能是 .textMessageContent / .toolCallStart / .reasoningMessageContent
}
```

解析逻辑核心：

```swift
if let content = delta.content {
    yield(.textMessageContent, payload: TextMessageContentPayload(...))
}
if let toolCalls = delta.toolCalls {
    yield(.toolCallStart / .toolCallArgs, ...)
}
if let reasoning = delta.reasoningContent {
    yield(.reasoningMessageContent, ...)
}
```

### 5.3 多轮工具调用

当一次回复包含工具调用时，`AIAgent` 会：

1. 发出 `STEP_STARTED`；
2. 逐个执行工具，发出 `TOOL_CALL_END` 与 `TOOL_CALL_RESULT`；
3. 将结果以 `role: tool` 的消息追加到对话历史；
4. 再次请求 LLM，获取最终面向用户的回复；
5. 发出 `STEP_FINISHED` 与 `RUN_FINISHED`。

### 5.4 修改建议的 "等待确认" 状态

当 `apply_markdown_edit` 工具被调用时，ToolRegistry 会发布通知：

```swift
NotificationCenter.default.post(
    name: .pendingMarkdownEdit,
    object: nil,
    userInfo: ["markdown": markdown, "reason": reason]
)
```

`AIAgent` 监听到后，创建 `PendingEdit`，并发出 `STATE_DELTA`：

```swift
StatePatchOperation(op: "add", path: "/pendingEdit", value: reason)
```

UI 侧显示修改建议卡片，用户点击 "应用" 或 "放弃" 后，再发出对应的 `STATE_DELTA`（`remove`）。

### 5.5 版本回溯与状态同步

应用修改前，`AIAgent` 会先保存快照：

```swift
VersionHistoryService.shared.saveVersion(text: text, reason: "AI 修改前快照", isAutoSave: true)
text = edit.suggestedText
VersionHistoryService.shared.saveVersion(text: text, reason: edit.reason, isAutoSave: true)
```

这样：

- 用户可以随时在版本历史中回滚；
- `STATE_SNAPSHOT` 可以在 Run 开始时发送当前文档状态；
- `STATE_DELTA` 可以精确描述文档变化。

---

## 6. 应用场景

### 6.1 流式 AI 写作助手

- 用户输入 "帮我写一段 Swift 代码"；
- UI 立即显示 `TEXT_MESSAGE_CONTENT` 片段；
- 用户看到 AI 逐字生成，而不是等待整段完成。

### 6.2 工具调用可视化

- AI 调用 `search_in_document` 搜索关键词；
- UI 显示 "正在调用 search_in_document..."；
- 搜索完成后显示结果摘要。

### 6.3 修改建议确认流

- AI 调用 `apply_markdown_edit` 提出全文润色；
- UI 弹出 Diff 摘要，等待用户确认；
- 用户确认后，文档更新并保存版本快照。

### 6.4 推理过程展示

- 使用支持推理的模型时，UI 可以通过 `REASONING_MESSAGE_CONTENT` 显示 "AI 的思考过程"；
- 增强透明度，让用户理解 AI 为什么给出某个答案。

### 6.5 跨端复用

- 同一套 `AGUIEvent` 可以在 macOS、iOS、Web 上渲染；
- 后端 Agent 不需要知道前端是 SwiftUI 还是 React。

---

## 7. AG-UI 解决了什么问题？

| 问题 | AG-UI 的解法 |
|------|--------------|
| 黑盒体验 | 将思考、工具调用、错误全部事件化 |
| 流式展示 | `TEXT_MESSAGE_CONTENT` 天然支持增量渲染 |
| 工具调用不可见 | `TOOL_CALL_*` 事件完整描述工具生命周期 |
| 状态不同步 | `STATE_SNAPSHOT` / `STATE_DELTA` 明确状态变更 |
| 多端复用难 | 标准化事件格式，前后端解耦 |
| 可观测性差 | 事件流本身即可被日志、监控、回放 |

---

## 8. 与 A2UI 的关系

AG-UI 与 A2UI（Agent-to-User Interface）是互补关系：

- **AG-UI**：负责**运行时事件传输**（Streaming、Tool Call、State）；
- **A2UI**：负责**声明式 UI 描述**（AI 告诉 UI 应该渲染什么组件）。

类比：

- AG-UI 像是 "神经系统中的电信号"；
- A2UI 像是 "大脑给肌肉发的动作指令"。

在 TechMarkdown 中，目前主要使用 AG-UI 实现运行时事件流；A2UI 类型的能力可以通过 `CUSTOM` 事件进行扩展。

---

## 9. 事件流示例

一次包含工具调用和修改建议的完整 Run：

```
RUN_STARTED
TEXT_MESSAGE_START
TEXT_MESSAGE_CONTENT: "我来帮你润色文档。"
TOOL_CALL_START: apply_markdown_edit
TOOL_CALL_ARGS: {"markdown": "# 标题\n...", "reason": "..."}
TOOL_CALL_END
STEP_STARTED: 工具执行
TOOL_CALL_RESULT: "修改建议已生成，等待用户在侧边栏确认。"
STEP_FINISHED: 工具执行
STATE_DELTA: add /pendingEdit "全文润色"
TEXT_MESSAGE_CONTENT: "请查看侧边栏的修改建议。"
TEXT_MESSAGE_END
RUN_FINISHED
```

用户确认应用后：

```
STATE_DELTA: remove /pendingEdit
STATE_SNAPSHOT: { document: "# 标题\n..." }
```

---

## 10. 面试常见问题

### Q1: AG-UI 和 OpenAI 的 SSE 有什么区别？

**A**: OpenAI SSE 是**模型提供商的传输格式**，描述的是 token 增量。AG-UI 是**Agent-UI 之间的语义协议**，描述的是更高层的运行时事件（消息、工具、状态、推理）。AG-UI 可以在 OpenAI SSE 之上构建。

### Q2: 如何处理工具调用失败？

**A**: `TOOL_CALL_RESULT` 的 `error` 字段可以携带错误信息；UI 可以据此显示重试按钮或错误提示。Agent 也可以将错误作为 `role: tool` 消息回填给 LLM，让模型自我修复。

### Q3: `STATE_DELTA` 为什么用 JSON Patch？

**A**: JSON Patch（RFC 6902）是描述文档增删改的标准格式，轻量、可序列化、易于应用和回滚，非常适合实现版本回溯与状态同步。

### Q4: 没有流式模型怎么办？

**A**: 可以在本地将非流式响应转换为 AG-UI 事件序列：`RUN_STARTED → TEXT_MESSAGE_START → TEXT_MESSAGE_CONTENT(完整内容) → TEXT_MESSAGE_END → RUN_FINISHED`。AG-UI 并不要求底层一定是流式传输。

---

## 11. 结语

AG-UI 让 AI Agent 的 "内心戏" 变得可见、可控、可复用。在 TechMarkdown 中，它不仅是技术实现，更是产品体验的升级：

- 流式回复更自然；
- 工具调用更透明；
- 修改建议更安全；
- 版本回溯更可靠。

随着 Agent 应用越来越复杂，AG-UI 这类标准化协议会成为连接 "智能" 与 "界面" 的关键桥梁。
