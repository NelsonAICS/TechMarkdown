# MCP（Model Context Protocol）扩展设计

## 1. 什么是 MCP？

MCP（Model Context Protocol）是 Anthropic 提出的开放协议，用于标准化 LLM 应用与外部数据源、工具之间的集成。它让 AI 应用可以像插拔 USB 一样连接各种能力扩展。

核心概念：

- **MCP Server**：提供工具、资源、提示的独立进程或服务。
- **MCP Client**：应用端的客户端，负责连接 Server 并调用其能力。
- **Transport**：通信方式，常见有 stdio、SSE、HTTP。

## 2. TechMarkdown 中的 MCP 定位

在 TechMarkdown 中，MCP 用于**扩展工具能力**。内置工具覆盖本地文件和文档操作，而 MCP 可以接入更专业的能力：

- 搜索引擎 MCP
- 数据库查询 MCP
- Git 操作 MCP
- 浏览器自动化 MCP
- 企业内部知识库 MCP

## 3. MCP 客户端协议

```swift
// Services/MCPClient.swift
protocol MCPClientProtocol: AnyObject {
    var name: String { get }
    var isConnected: Bool { get }
    func connect() async throws
    func disconnect()
    func listTools() async throws -> [ToolDefinition]
    func callTool(name: String, arguments: [String: Any]) async throws -> String
}
```

这个协议抽象了任意 MCP Server 的接入方式，符合面向接口编程原则。

## 4. HTTP MCP 客户端实现

当前版本提供了一个基于 HTTP 的简化 MCP 客户端：

```swift
// Services/MCPClient.swift
final class HTTPMCPClient: MCPClientProtocol {
    let name: String
    private let endpoint: URL
    private(set) var isConnected = false
    
    func connect() async throws {
        // 发送 GET 探测连接
        ...
        isConnected = true
    }
    
    func listTools() async throws -> [ToolDefinition] {
        // GET /tools 获取工具列表
        ...
    }
    
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        // POST /call 调用工具
        ...
    }
}
```

**注意**：这是教学级简化实现，真实的 MCP stdio/SSE 实现需要处理 JSON-RPC、会话管理、生命周期等复杂逻辑。

## 5. MCP 配置管理

```swift
// Services/MCPClient.swift
struct MCPConfiguration: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var transport: MCPTransport
    var endpoint: String
    var isEnabled: Bool
}

enum MCPTransport: String, Codable, CaseIterable {
    case stdio
    case sse
    case http
}
```

`MCPManager` 负责：

- 维护配置列表
- 批量连接启用的 Server
- 汇总发现的工具
- 提供给 `AIAgent` 使用

```swift
// Services/MCPClient.swift
@Observable
final class MCPManager {
    var configurations: [MCPConfiguration] = []
    var activeClients: [MCPClientProtocol] = []
    var discoveredTools: [ToolDefinition] = []
    
    func addConfiguration(_ config: MCPConfiguration) { ... }
    func removeConfiguration(id: UUID) { ... }
    func connectAll() async { ... }
}
```

## 6. 与 AI Agent 集成

`AIAgent.performChatRound` 收集可用工具时，会把 MCP 发现的工具与内置工具合并：

```swift
// Services/AIAgent.swift
var availableTools = ToolRegistry.shared.allDefinitions
availableTools.append(contentsOf: mcpManager.discoveredTools)
```

这意味着用户无需关心工具来自内置还是外部 MCP，LLM 统一按 `ToolDefinition` 调用。

## 7. 为什么先做 HTTP 而不是 stdio？

| 传输方式 | 优点 | 缺点 | 当前选择 |
|---|---|---|---|
| stdio | 本地安全、无端口占用 | 需要进程管理、JSON-RPC 复杂 | 未来扩展 |
| SSE | 实时推送 | 长连接管理、调试复杂 | 未来扩展 |
| HTTP | 简单、易调试、与 Web 服务兼容 | 需要服务预先启动 | 当前实现 |

HTTP 版本适合面试项目演示和快速接入已有的 REST 服务，降低实现复杂度。

## 8. 如何接入一个自定义 MCP Server

假设有一个本地 Python 服务运行在 `http://127.0.0.1:8000`：

```python
from fastapi import FastAPI
app = FastAPI()

@app.get("/tools")
def tools():
    return [
        {"name": "search_web", "description": "搜索网页"},
        {"name": "fetch_url", "description": "获取网页内容"}
    ]

@app.post("/call")
def call(req: dict):
    if req["name"] == "search_web":
        return {"result": "搜索结果..."}
    return {"result": "unknown"}
```

在 TechMarkdown 的「AI 设置 → MCP Server」中添加：

- 名称：MySearch
- 端点：`http://127.0.0.1:8000`
- 协议：HTTP

点击「连接全部」后，`search_web` 和 `fetch_url` 就会出现在可用工具列表中。

## 9. 面试常见问题

**Q: MCP 和传统 API 集成有什么区别？**

A: MCP 是标准化协议，定义了统一的工具发现、调用、上下文传递方式。传统 API 集成需要为每个服务写适配代码；MCP 让不同服务以相同接口被 LLM 使用。

**Q: 如果 MCP Server 不可用怎么办？**

A: `MCPManager.connectAll()` 会捕获连接异常，只把成功连接的工具加入 `discoveredTools`。LLM 不会调用未发现的工具，系统保持可用。

**Q: 如何设计一个稳定的 MCP Client？**

A: 需要考虑：连接超时重试、心跳保活、进程生命周期管理（stdio）、错误隔离、工具 schema 校验、调用结果大小限制。当前版本做了基础抽象，生产环境可在此基础上扩展。
