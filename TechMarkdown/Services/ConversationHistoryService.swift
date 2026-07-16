import Foundation

/// 对话历史持久化服务
/// 将对话以 JSON 形式保存在 Application Support/Conversations 目录下，
/// 并提供列表、加载、删除能力。
final class ConversationHistoryService {
    static let shared = ConversationHistoryService()
    private init() {
        ensureDirectoryExists()
    }
    
    private var directoryURL: URL {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportURL.appendingPathComponent("com.example.TechMarkdown/Conversations", isDirectory: true)
    }
    
    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
    
    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }
    
    /// 保存对话
    func save(_ conversation: Conversation) {
        ensureDirectoryExists()
        let url = fileURL(for: conversation.id)
        if let data = try? JSONEncoder().encode(conversation) {
            try? data.write(to: url)
        }
    }
    
    /// 加载所有对话，按更新时间倒序
    func list() -> [Conversation] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Conversation? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(Conversation.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    
    /// 根据 ID 加载单条对话
    func load(id: UUID) -> Conversation? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Conversation.self, from: data)
    }
    
    /// 删除对话
    func delete(id: UUID) {
        let url = fileURL(for: id)
        try? FileManager.default.removeItem(at: url)
    }
    
    /// 根据消息生成标题：取第一条用户消息的前 20 个字符
    func generateTitle(from messages: [ChatMessage]) -> String {
        guard let firstUserMessage = messages.first(where: { $0.role == .user }) else {
            return "未命名对话"
        }
        let content = firstUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(content.prefix(20))
        return prefix.isEmpty ? "未命名对话" : prefix
    }
}
