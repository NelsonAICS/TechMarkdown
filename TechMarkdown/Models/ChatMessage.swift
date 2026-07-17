import Foundation

enum ChatRole: String, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var role: ChatRole
    var content: String
    var toolCalls: [ToolCall]?
    var toolCallID: String?
    var timestamp: Date
    var referencedFiles: [ReferencedFile]
    var reasoningContent: String?
    var runID: UUID?
    
    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil,
        timestamp: Date = Date(),
        referencedFiles: [ReferencedFile] = [],
        reasoningContent: String? = nil,
        runID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.timestamp = timestamp
        self.referencedFiles = referencedFiles
        self.reasoningContent = reasoningContent
        self.runID = runID
    }
    
    var isUser: Bool { role == .user }
    var isAssistant: Bool { role == .assistant }
}

extension ChatMessage {
    /// 将消息转换为 OpenAI Chat Completions API 所需的字典格式
    func dictionaryRepresentations() -> [[String: Any]] {
        var result: [[String: Any]] = []
        
        // 如果存在工具调用，需要以 assistant 消息形式发送 tool_calls
        if role == .assistant, let toolCalls = toolCalls, !toolCalls.isEmpty {
            let calls: [[String: Any]] = toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.function.name,
                        "arguments": call.function.arguments
                    ]
                ]
            }
            result.append([
                "role": role.rawValue,
                "content": self.content,
                "tool_calls": calls
            ])
        } else if role == .tool, let toolCallID = toolCallID {
            result.append([
                "role": role.rawValue,
                "content": self.content,
                "tool_call_id": toolCallID
            ])
        } else {
            result.append([
                "role": role.rawValue,
                "content": self.content
            ])
        }
        
        return result
    }
}

struct ReferencedFile: Codable, Hashable, Identifiable {
    let id: UUID
    var path: String
    var contentPreview: String
    var isIncluded: Bool
}

struct ToolCall: Codable, Hashable, Identifiable {
    let id: String
    let function: ToolCallFunction
    
    var name: String { function.name }
    var argumentsString: String { function.arguments }
}

struct ToolCallFunction: Codable, Hashable {
    let name: String
    let arguments: String
}

struct PendingEdit: Identifiable, Codable, Equatable {
    let id: UUID
    var originalText: String
    var suggestedText: String
    var reason: String
    var hunks: [EditHunk] = []
    var runID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        originalText: String,
        suggestedText: String,
        reason: String,
        hunks: [EditHunk] = [],
        runID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.originalText = originalText
        self.suggestedText = suggestedText
        self.reason = reason
        self.hunks = hunks
        self.runID = runID
        self.createdAt = createdAt
    }
}

/// AI 修改建议中的可独立应用/弃用的差异块。
struct EditHunk: Identifiable, Codable, Equatable {
    let id: UUID
    /// 在 originalText 中的 1-based 起始行号
    var oldStart: Int
    /// 被替换/删除的原始行
    var oldLines: [String]
    /// 建议的新行
    var newLines: [String]

    init(
        id: UUID = UUID(),
        oldStart: Int,
        oldLines: [String],
        newLines: [String]
    ) {
        self.id = id
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newLines = newLines
    }

    var oldCount: Int { oldLines.count }
    var newCount: Int { newLines.count }
    var isInsertion: Bool { oldLines.isEmpty }
    var isDeletion: Bool { newLines.isEmpty }
    var isReplacement: Bool { !oldLines.isEmpty && !newLines.isEmpty }
}

struct SelectedTextSnippet: Identifiable, Codable, Hashable {
    let id: UUID
    var content: String
    var timestamp: Date
    
    init(id: UUID = UUID(), content: String, timestamp: Date = Date()) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
    }
    
    var preview: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}
