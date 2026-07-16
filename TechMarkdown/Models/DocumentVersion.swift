import Foundation

/// 文档版本快照，用于版本回溯
struct DocumentVersion: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let text: String
    let reason: String
    let isAutoSave: Bool
    
    var displayTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: timestamp)
    }
}
