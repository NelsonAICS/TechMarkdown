import Foundation

/// 一条保存的对话记录
struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    var threadID: String
    var context: ConversationContext
    var isPinned: Bool
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        threadID: String = UUID().uuidString,
        context: ConversationContext = ConversationContext(),
        isPinned: Bool = false,
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.threadID = threadID
        self.context = context
        self.isPinned = isPinned
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case updatedAt
        case messages
        case threadID
        case context
        case isPinned
        case isArchived
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID) ?? id.uuidString
        context = try container.decodeIfPresent(ConversationContext.self, forKey: .context) ?? ConversationContext()
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}
