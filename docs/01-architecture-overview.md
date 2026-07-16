# TechMarkdown + AI Agent 架构总览

## 1. 项目定位

TechMarkdown 是一个面向 macOS 的原生 Markdown 编辑器，在原有实时预览、科技风主题、文件对比等功能基础上，升级为**「Markdown 处理和解读 Agent」**。用户不仅可以编辑 Markdown，还可以通过 AI 侧边栏：

- 对当前文档提问
- 获取修改建议并一键应用
- 引用本地文件作为上下文
- 通过 Tool Use / Skill / MCP 扩展能力

## 2. 技术栈

| 层级 | 技术 |
|---|---|
| UI 框架 | SwiftUI + AppKit (WKWebView) |
| 最低系统 | macOS 14.0 |
| Swift 版本 | 5.10 |
| 状态管理 | SwiftUI `@Observable` |
| AI 协议 | OpenAI-compatible Chat Completions |
| 公式渲染 | KaTeX (CDN) |
| Markdown 解析 | marked.js (CDN) |
| 代码高亮 | highlight.js (CDN) |
| 安全存储 | macOS Keychain |
| 沙盒 | App Sandbox + network.client |

## 3. 核心架构图

```
┌─────────────────────────────────────────────────────────────┐
│                        TechMarkdown App                      │
│  ┌─────────────┐  ┌─────────────────────┐  ┌──────────────┐ │
│  │  文档侧边栏  │  │   编辑区 / 预览区    │  │  AI 侧边栏   │ │
│  │  (Stats)    │  │  (Editor/Preview)   │  │ (Chat/Skill) │ │
│  └──────┬──────┘  └──────────┬──────────┘  └──────┬───────┘ │
│         │                    │                    │         │
│         └────────────────────┼────────────────────┘         │
│                              ▼                               │
│                    ┌──────────────────┐                      │
│                    │  MarkdownDocument │                     │
│                    │  (FileDocument)   │                     │
│                    └────────┬─────────┘                      │
│                             ▼                                │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                      AIAgent                            │ │
│  │  ┌──────────┐  ┌─────────────┐  ┌────────────────────┐ │ │
│  │  │ ChatHistory│  │ ToolRegistry │  │   SkillRegistry    │ │ │
│  │  └──────────┘  └──────┬──────┘  └────────────────────┘ │ │
│  │                       │                                 │ │
│  │  ┌────────────────────┴─────────────────────────────┐   │ │
│  │  │              AIService (OpenAI API)               │   │ │
│  │  └───────────────────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────┘ │
│                              ▲                                │
│                 ┌────────────┴────────────┐                  │
│                 │        MCPManager         │                  │
│                 │  (MCP Server 注册与发现)   │                  │
│                 └───────────────────────────┘                  │
└─────────────────────────────────────────────────────────────┘
```

## 4. 模块职责

### 4.1 Models

- `MarkdownDocument`：符合 `FileDocument` 的文档模型，支持 `.md` 读写与文件关联。
- `ChatMessage` / `ReferencedFile` / `PendingEdit`：AI 对话状态。
- `AIProviderConfiguration`：AI 服务商配置（OpenAI / Gemini / 豆包 / 千问 / 自定义）。
- `ToolDefinition` / `ToolResult`：Tool Use 的声明与结果。
- `SkillDefinition`：Skill 的元数据与 prompt 模板。

### 4.2 Services

- `AIService`：封装 OpenAI-compatible HTTP 请求，支持文本、工具调用。
- `AIAgent`： orchestrator，管理对话历史、工具调用链、Skill 执行、文件引用与待确认修改。
- `ToolRegistry`：内置工具注册中心（读文件、列目录、搜索文档、应用编辑）。
- `FileContextService`：本地文件读取与 `@path` 引用解析。
- `MarkdownEditService`：从 AI 回复中提取可应用的 Markdown 修改（备用路径）。
- `KeychainService`：安全保存 API Key。
- `MCPManager` / `MCPClientProtocol` / `HTTPMCPClient`：外部 MCP Server 接入框架。

### 4.3 Views

- `ContentView`：三栏布局（文档统计 / 编辑预览 / AI 侧边栏）。
- `AISidebarView`：AI 对话、Skill 选择、文件引用、修改确认。
- `AISettingsView`：服务商配置、API Key、MCP 管理。
- `PreviewView`：WKWebView 渲染 Markdown + KaTeX + 代码高亮。

## 5. 数据流

1. 用户在编辑器输入 Markdown → `MarkdownDocument.text` 更新。
2. `ContentView` 将 `document.text` 同步给 `PreviewView` 和 `AIAgent`。
3. 用户在 AI 侧边栏输入问题 → `AIAgent.sendMessage`。
4. `AIAgent` 组装 system prompt（含当前文档 + 引用文件）+ 历史消息 + 工具描述。
5. `AIService` 请求 LLM，返回内容或 `tool_calls`。
6. 如需工具调用，`ToolRegistry.execute` 执行，结果再次喂给 LLM。
7. 若触发 `apply_markdown_edit`，生成 `PendingEdit` 等待用户确认。
8. 用户点击「应用」→ 修改写入 `document.text`。

## 6. 关键技术选型原因

### 6.1 为什么使用 `@Observable` 而不是 `ObservableObject`？

macOS 14 引入的 `@Observable` 提供更细粒度的依赖追踪，视图只会在真正访问的属性变化时重绘。相比 `ObservableObject` 的 `@Published` 全对象重绘，性能更好，代码也更简洁。

### 6.2 为什么使用 OpenAI-compatible 协议？

国内主流大模型（豆包、千问、智谱）均提供 OpenAI 兼容接口，使用统一协议可以一套代码支持多个服务商，用户只需配置 baseURL、model 和 apiKey。

### 6.3 为什么用 WKWebView 而不是原生 Markdown 渲染？

WKWebView 可以无缝集成成熟的前端库（marked.js + KaTeX + highlight.js），完整支持 LaTeX、代码高亮、表格等复杂 Markdown 特性，且主题切换通过 CSS 即可实现，开发成本低、渲染效果好。

### 6.4 为什么把 API Key 存 Keychain？

API Key 属于敏感凭证，UserDefaults 明文存储不安全。Keychain 提供加密存储，且支持 iCloud Keychain 同步，符合 macOS 安全最佳实践。

## 7. 可扩展性设计

- **Tool Use**：新增工具只需实现 `ToolExecutable` 并注册到 `ToolRegistry`。
- **Skill**：新增 Skill 只需定义 `SkillDefinition`，无需改动核心对话逻辑。
- **MCP**：`MCPClientProtocol` 抽象了外部 Server 接入，可接入任意 MCP 服务。
- **Provider**：`AIProviderID` 枚举式管理预设，新增服务商只需添加 case。

## 8. 面试价值

本项目覆盖了 AI Agent 应用开发的多个高频面试点：

- LLM 调用与多轮对话管理
- Function Calling / Tool Use 实现
- RAG 思想的本地文件上下文注入
- 记忆系统（对话历史）
- MCP 协议理解与扩展点设计
- macOS 原生应用工程化（Keychain、Sandbox、SwiftUI）
