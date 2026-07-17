import Foundation

/// 文档版本历史服务
/// 负责在关键节点（用户保存、AI 修改应用前/后）创建快照，并支持回溯到任意版本。
final class VersionHistoryService {
    static let shared = VersionHistoryService()
    private init() {}
    
    private let maxVersionsPerFile = 50
    private let maxStoredVersions = 500
    private let queue = DispatchQueue(label: "com.techmarkdown.version-history", qos: .utility)
    
    /// 保存一个版本快照
    func saveVersion(
        id: UUID = UUID(),
        text: String,
        reason: String,
        isAutoSave: Bool = false,
        filePath: String? = nil,
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        editID: UUID? = nil,
        parentVersionID: UUID? = nil
    ) {
        queue.async {
            var versions = self.loadAllVersions()
            let version = DocumentVersion(
                id: id,
                text: text,
                reason: reason,
                isAutoSave: isAutoSave,
                filePath: filePath,
                conversationID: conversationID,
                runID: runID,
                editID: editID,
                parentVersionID: parentVersionID
            )
            versions.insert(version, at: 0)
            versions = self.trimmed(versions)
            self.persist(versions)
        }
    }
    
    /// 加载所有版本（同步，供 UI 使用）
    func loadAllVersions() -> [DocumentVersion] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let versions = try? JSONDecoder().decode([DocumentVersion].self, from: data) else {
            return []
        }
        return versions
    }

    /// 只读取当前文件的版本链。旧数据没有文件路径时不会错误归属给任意文件。
    func loadAllVersions(forFilePath filePath: String?) -> [DocumentVersion] {
        loadAllVersions().filter { $0.filePath == filePath }
    }
    
    /// 获取某个版本的内容
    func version(withId id: UUID) -> DocumentVersion? {
        loadAllVersions().first { $0.id == id }
    }
    
    /// 删除某个版本
    func deleteVersion(id: UUID) {
        queue.async {
            var versions = self.loadAllVersions()
            versions.removeAll { $0.id == id }
            self.persist(versions)
        }
    }
    
    /// 清空历史
    func clearHistory() {
        queue.async {
            UserDefaults.standard.removeObject(forKey: self.storageKey)
        }
    }
    
    private var storageKey: String {
        "techmarkdown.documentVersions"
    }
    
    private func persist(_ versions: [DocumentVersion]) {
        if let data = try? JSONEncoder().encode(versions) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func trimmed(_ versions: [DocumentVersion]) -> [DocumentVersion] {
        var counts: [String: Int] = [:]
        return versions.filter { version in
            let scope = version.filePath ?? "__legacy__"
            let count = counts[scope, default: 0]
            guard count < maxVersionsPerFile else { return false }
            counts[scope] = count + 1
            return true
        }
        .prefix(maxStoredVersions)
        .map { $0 }
    }
}
