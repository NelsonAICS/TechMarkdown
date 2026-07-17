import Foundation

/// 文档版本快照，用于版本回溯
struct DocumentVersion: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let text: String
    let reason: String
    let isAutoSave: Bool
    /// 将版本快照绑定到具体文件和 Agent 修改链，避免不同文档历史混在一起。
    let filePath: String?
    let conversationID: UUID?
    let runID: UUID?
    let editID: UUID?
    let parentVersionID: UUID?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        text: String,
        reason: String,
        isAutoSave: Bool,
        filePath: String? = nil,
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        editID: UUID? = nil,
        parentVersionID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.reason = reason
        self.isAutoSave = isAutoSave
        self.filePath = filePath
        self.conversationID = conversationID
        self.runID = runID
        self.editID = editID
        self.parentVersionID = parentVersionID
    }
    
    var displayTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: timestamp)
    }
}
