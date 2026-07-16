# TechMarkdown AI Agent 文档

欢迎来到 TechMarkdown AI Agent 模块文档目录。

## 文档索引

| 文档 | 内容 |
|---|---|
| [01-architecture-overview.md](01-architecture-overview.md) | 整体架构设计、模块职责、数据流 |
| [02-ai-agent-integration.md](02-ai-agent-integration.md) | AI Agent 集成设计、对话流程、System Prompt |
| [03-tool-use-and-skills.md](03-tool-use-and-skills.md) | Tool Use 框架、Skill 设计、内置工具 |
| [04-mcp-design.md](04-mcp-design.md) | MCP 扩展协议、HTTP Client、与 Agent 集成 |
| [05-memory-and-context.md](05-memory-and-context.md) | 上下文组装、Token 控制、本地文件引用 |
| [06-edit-suggestion-flow.md](06-edit-suggestion-flow.md) | 修改建议、Diff 预览、确认流程 |
| [07-problems-and-solutions.md](07-problems-and-solutions.md) | 实现过程中遇到的问题与解决方案 |
| [08-interview-qa.md](08-interview-qa.md) | 面试问答集锦 |
| [09-build-and-run.md](09-build-and-run.md) | 构建与运行指南 |
| [10-ag-ui-protocol.md](10-ag-ui-protocol.md) | AG-UI 事件协议规范 |
| [11-document-retrieval.md](11-document-retrieval.md) | 文档检索与上下文注入 |
| [12-intent-recognition.md](12-intent-recognition.md) | 用户意图识别设计 |
| [13-vendor-api-configurations.md](13-vendor-api-configurations.md) | 模型厂商 API 配置规范 |

## 快速开始

1. 打开 TechMarkdown 根目录。
2. 运行 `swift build` 验证编译。
3. 在 macOS 上打开 `TechMarkdown.xcodeproj`（推荐）或直接用 Xcode 打开 Package。
4. 配置 AI Provider：进入「AI 设置」，选择 Provider 并输入 API Key。
5. 打开 AI 侧边栏，开始与 AI 对话。

## 核心流程图

```
┌─────────────┐     输入问题/Skill     ┌──────────┐
│ AISidebarView│ ───────────────────▶ │ AIAgent  │
└─────────────┘                        └────┬─────┘
                                            │
              ┌─────────────────────────────┼─────────────────────────────┐
              ▼                             ▼                             ▼
      ┌───────────────┐           ┌─────────────────┐           ┌─────────────────┐
      │ FileContext   │           │ ToolRegistry    │           │ MCPManager      │
      │ Service       │           │ (Built-in Tools)│           │ (External MCP)  │
      └───────────────┘           └─────────────────┘           └─────────────────┘
                                            │
                                            ▼
                                    ┌───────────────┐
                                    │ OpenAI API    │
                                    │ (Compatible)  │
                                    └───────┬───────┘
                                            │
              ┌─────────────────────────────┼─────────────────────────────┐
              ▼                             ▼                             ▼
       ┌──────────────┐           ┌─────────────────┐           ┌─────────────────┐
       │ Streamed UI  │           │ Tool Calls      │           │ PendingEdit     │
       │ Update       │           │ Execution       │           │ Confirm/Apply   │
       └──────────────┘           └─────────────────┘           └─────────────────┘
```

## 面试用途

本项目的完整文档可用于：

- 简历项目描述素材
- 面试中的技术细节回答
- 系统设计题案例
- AI Agent / LLM 应用开发知识整理

建议重点阅读：

- [01-architecture-overview.md](01-architecture-overview.md) 的架构图和模块说明
- [02-ai-agent-integration.md](02-ai-agent-integration.md) 的对话流程和 System Prompt
- [03-tool-use-and-skills.md](03-tool-use-and-skills.md) 的 Function Calling 流程
- [08-interview-qa.md](08-interview-qa.md) 的面试问答
- [09-build-and-run.md](09-build-and-run.md) 的构建步骤
