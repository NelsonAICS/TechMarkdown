import Foundation

/// MCP (Model Context Protocol) 客户端协议
/// 用于连接外部 MCP Server，扩展 TechMarkdown 的工具能力
protocol MCPClientProtocol: AnyObject {
    var name: String { get }
    var isConnected: Bool { get }
    var lastError: String? { get }
    func connect() async throws
    func disconnect()
    func close() async
    func initialize() async throws
    func notifyInitialized() async throws
    func healthCheck() async -> Bool
    func listTools() async throws -> [ToolDefinition]
    func callTool(name: String, arguments: [String: Any]) async throws -> String
}

/// MCP 连接配置
struct MCPConfiguration: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var transport: MCPTransport
    var endpoint: String
    var isEnabled: Bool
    var authToken: String?
    var timeout: TimeInterval = 30
    
    enum MCPTransport: String, Codable, CaseIterable {
        case stdio
        case sse
        case http
    }
}

/// HTTP/SSE 类型的 MCP 客户端基础实现
final class HTTPMCPClient: MCPClientProtocol {
    let name: String
    private let endpoint: URL
    private let authToken: String?
    private let timeout: TimeInterval
    private var session: URLSession
    private(set) var isConnected = false
    private(set) var lastError: String?
    
    init(name: String, endpoint: URL, authToken: String? = nil, timeout: TimeInterval = 30) {
        self.name = name
        self.endpoint = endpoint
        self.authToken = authToken
        self.timeout = timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        self.session = URLSession(configuration: config)
    }
    
    func connect() async throws {
        for attempt in 0..<3 {
            if await healthCheck() {
                do {
                    try await initialize()
                    try await notifyInitialized()
                    isConnected = true
                    self.lastError = nil
                    return
                } catch {
                    self.lastError = error.localizedDescription
                }
            }
            if attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64((attempt + 1) * 1_000_000_000))
            }
        }
        throw lastError.map { MCPError.requestFailed($0) } ?? MCPError.connectionFailed
    }
    
    func disconnect() {
        isConnected = false
    }
    
    func close() async {
        isConnected = false
        session.invalidateAndCancel()
    }
    
    func initialize() async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("initialize"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": [
                    "name": "TechMarkdown",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                ]
            ]
        ])
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            throw MCPError.requestFailed("initialize 响应无效")
        }
        if let protocolVersion = result["protocolVersion"] as? String {
            print("MCP server protocol version: \(protocolVersion)")
        }
    }
    
    func notifyInitialized() async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("notifications/initialized"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ])
        let (_, response) = try await session.data(for: request)
        try validateResponse(response, data: Data())
    }
    
    func healthCheck() async -> Bool {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            applyAuth(to: &request)
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            let healthy = httpResponse.statusCode < 500
            if !healthy {
                lastError = "健康检查失败，HTTP \(httpResponse.statusCode)"
            }
            return healthy
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
    
    func listTools() async throws -> [ToolDefinition] {
        guard isConnected else {
            throw MCPError.connectionFailed
        }
        var request = URLRequest(url: endpoint.appendingPathComponent("tools"))
        request.httpMethod = "GET"
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        
        return json.compactMap { dict in
            guard let name = dict["name"] as? String,
                  let description = dict["description"] as? String else { return nil }
            return ToolDefinition(
                name: name,
                description: description,
                parameters: [],
                requiredParameters: []
            )
        }
    }
    
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        guard isConnected else {
            throw MCPError.connectionFailed
        }
        var request = URLRequest(url: endpoint.appendingPathComponent("call"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "arguments": arguments
        ])
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    private func applyAuth(to request: inout URLRequest) {
        if let token = authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
    
    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.connectionFailed
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw MCPError.authenticationFailed
        }
        if httpResponse.statusCode >= 400 {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw MCPError.requestFailed(errorText)
        }
    }
}

enum MCPError: Error, LocalizedError {
    case connectionFailed
    case invalidEndpoint
    case toolNotFound
    case authenticationFailed
    case requestFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "MCP 连接失败"
        case .invalidEndpoint: return "无效的 MCP 端点"
        case .toolNotFound: return "MCP 工具未找到"
        case .authenticationFailed: return "MCP 认证失败，请检查 Token"
        case .requestFailed(let msg): return "MCP 请求失败: \(msg)"
        }
    }
}

/// MCP 管理器：负责注册、连接和发现外部 MCP Server
@Observable
final class MCPManager {
    static let shared = MCPManager()
    
    var configurations: [MCPConfiguration] = []
    var activeClients: [MCPClientProtocol] = []
    var discoveredTools: [ToolDefinition] = []
    var connectionErrors: [String: String] = [:]
    private var toolClients: [String: MCPClientProtocol] = [:]
    
    private init() {
        loadSavedConfigurations()
    }
    
    func addConfiguration(_ config: MCPConfiguration) {
        configurations.append(config)
        saveConfigurations()
    }
    
    func removeConfiguration(id: UUID) {
        configurations.removeAll { $0.id == id }
        saveConfigurations()
    }
    
    func loadSavedConfigurations() {
        guard let data = UserDefaults.standard.data(forKey: "techmarkdown.mcpConfigurations"),
              let saved = try? JSONDecoder().decode([MCPConfiguration].self, from: data) else {
            return
        }
        configurations = saved
    }
    
    func saveConfigurations() {
        if let data = try? JSONEncoder().encode(configurations) {
            UserDefaults.standard.set(data, forKey: "techmarkdown.mcpConfigurations")
        }
    }
    
    func connectAll() async {
        activeClients.removeAll()
        discoveredTools.removeAll()
        connectionErrors.removeAll()
        toolClients.removeAll()
        
        for config in configurations where config.isEnabled {
            guard let url = URL(string: config.endpoint) else {
                connectionErrors[config.name] = "无效端点"
                continue
            }
            let client = HTTPMCPClient(
                name: config.name,
                endpoint: url,
                authToken: config.authToken,
                timeout: config.timeout
            )
            do {
                try await client.connect()
                activeClients.append(client)
                let tools = try await client.listTools()
                discoveredTools.append(contentsOf: tools)
                for tool in tools {
                    toolClients[tool.name] = client
                }
            } catch {
                connectionErrors[config.name] = error.localizedDescription
                print("MCP 连接失败 \(config.name): \(error)")
            }
        }
    }
    
    func reconnect(clientName: String) async {
        guard let config = configurations.first(where: { $0.name == clientName && $0.isEnabled }),
              let url = URL(string: config.endpoint) else { return }
        
        activeClients.removeAll { $0.name == clientName }
        toolClients = toolClients.filter { $0.value.name != clientName }
        connectionErrors[config.name] = nil
        
        let client = HTTPMCPClient(
            name: config.name,
            endpoint: url,
            authToken: config.authToken,
            timeout: config.timeout
        )
        do {
            try await client.connect()
            activeClients.append(client)
            let tools = try await client.listTools()
            discoveredTools.append(contentsOf: tools)
            for tool in tools {
                toolClients[tool.name] = client
            }
        } catch {
            connectionErrors[config.name] = error.localizedDescription
        }
    }

    func execute(toolCall: ToolCall) async -> ToolResult {
        guard let client = toolClients[toolCall.name] else {
            return ToolResult(
                toolCallID: toolCall.id,
                name: toolCall.name,
                output: "未找到可执行该工具的 MCP 服务：\(toolCall.name)",
                isError: true
            )
        }
        do {
            guard
                let data = toolCall.argumentsString.data(using: .utf8),
                let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return ToolResult(
                    toolCallID: toolCall.id,
                    name: toolCall.name,
                    output: "无法解析 MCP 工具参数",
                    isError: true
                )
            }
            let output = try await client.callTool(name: toolCall.name, arguments: arguments)
            return ToolResult(
                toolCallID: toolCall.id,
                name: toolCall.name,
                output: output
            )
        } catch {
            return ToolResult(
                toolCallID: toolCall.id,
                name: toolCall.name,
                output: "MCP 工具执行错误：\(error.localizedDescription)",
                isError: true
            )
        }
    }
}
