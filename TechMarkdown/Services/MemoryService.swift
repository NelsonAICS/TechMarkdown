import Foundation

/// AI 核心记忆服务
/// 维护两类持久化记忆：/// 1. 用户画像（写作风格、行为规范、习惯、研究类型、工作习惯）/// 2. 文件索引（用户编辑过的文件路径、标题、摘要、标签）
/// 这些内容会作为 system prompt 的一部分注入给 LLM，并提供查询工具。
final class MemoryService {
    static let shared = MemoryService()

    private let queue = DispatchQueue(label: "com.techmarkdown.memory", qos: .utility)
    let directoryURL: URL

    /// 默认初始化，使用应用 Application Support 目录。
    private convenience init() {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = supportURL.appendingPathComponent("com.example.TechMarkdown", isDirectory: true)
        self.init(directoryURL: directoryURL)
    }

    /// 可注入目录的初始化，用于测试或自定义存储位置。
    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        ensureDirectoryExists()
    }

    private var memoryFileURL: URL {
        directoryURL.appendingPathComponent("memory.md")
    }

    private var userProfileFileURL: URL {
        directoryURL.appendingPathComponent("user-profile.json")
    }

    private var fileIndexFileURL: URL {
        directoryURL.appendingPathComponent("file-index.json")
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    // MARK: - 传统 Markdown 记忆（保留兼容）

    /// 读取核心记忆，如果文件不存在则返回默认模板
    func loadMemory() -> String {
        ensureDirectoryExists()
        if let data = try? Data(contentsOf: memoryFileURL),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        return defaultMemoryTemplate
    }

    /// 保存核心记忆
    func saveMemory(_ text: String) {
        ensureDirectoryExists()
        try? text.write(to: memoryFileURL, atomically: true, encoding: .utf8)
    }

    /// 核心记忆文件路径，用于在编辑器中打开
    var memoryFilePath: String {
        memoryFileURL.path
    }

    // MARK: - 用户画像

    func loadUserProfile() -> UserProfileMemory {
        ensureDirectoryExists()
        guard let data = try? Data(contentsOf: userProfileFileURL),
              let profile = try? JSONDecoder().decode(UserProfileMemory.self, from: data) else {
            return .default
        }
        return profile
    }

    func saveUserProfile(_ profile: UserProfileMemory) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureDirectoryExists()
            if let data = try? JSONEncoder().encode(profile) {
                try? data.write(to: self.userProfileFileURL)
            }
        }
    }

    /// 生成用户画像的 system prompt 片段
    func profilePromptSection() -> String {
        let profile = loadUserProfile()
        let section = profile.promptSection
        return section.isEmpty ? "" : "用户画像（请据此调整回答风格与行为）：\n\(section)"
    }

    // MARK: - 文件索引

    private func loadFileIndexFromDisk() -> [FileIndexEntry] {
        ensureDirectoryExists()
        guard let data = try? Data(contentsOf: fileIndexFileURL),
              let entries = try? JSONDecoder().decode([FileIndexEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveFileIndexToDisk(_ entries: [FileIndexEntry]) {
        ensureDirectoryExists()
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileIndexFileURL, options: .atomic)
        }
    }

    /// 记录一次文件交互（打开或保存），自动更新标题、摘要、标签和时间戳
    func recordFileInteraction(path: String, text: String) {
        queue.sync {
            var entries = loadFileIndexFromDisk()
            let (title, summary, tags, wordCount) = self.summarize(text: text, path: path)
            let projectPath = URL(fileURLWithPath: path).deletingLastPathComponent().path

            if let index = entries.firstIndex(where: { $0.path == path }) {
                entries[index].title = title
                entries[index].summary = summary
                entries[index].tags = tags
                entries[index].wordCount = wordCount
                entries[index].projectPath = projectPath
                entries[index].lastModified = Date()
                entries[index].lastOpenedAt = Date()
            } else {
                let entry = FileIndexEntry(
                    id: UUID(),
                    path: path,
                    projectPath: projectPath,
                    title: title,
                    summary: summary,
                    tags: tags,
                    wordCount: wordCount,
                    lastModified: Date(),
                    lastOpenedAt: Date()
                )
                entries.append(entry)
            }

            // 保留最近 200 条，避免无限增长
            let trimmed = entries.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(200)
            saveFileIndexToDisk(Array(trimmed))
        }
    }

    /// 搜索文件索引，按路径/标题/摘要/标签/项目路径匹配
    func searchFileIndex(query: String) -> [FileIndexEntry] {
        queue.sync {
            let entries = loadFileIndexFromDisk()
            let normalized = query.lowercased()
            return entries.filter { entry in
                entry.path.lowercased().contains(normalized) ||
                entry.title.lowercased().contains(normalized) ||
                entry.summary.lowercased().contains(normalized) ||
                entry.projectPath?.lowercased().contains(normalized) ?? false ||
                entry.tags.contains { $0.lowercased().contains(normalized) }
            }
        }
    }

    /// 获取最近编辑的文件
    func recentFileIndexEntries(limit: Int = 10) -> [FileIndexEntry] {
        queue.sync {
            let entries = loadFileIndexFromDisk()
            return entries.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(limit).map { $0 }
        }
    }

    /// 清空文件索引（仅移除最近文件记录，不会删除磁盘上的文件）
    func clearFileIndex() {
        queue.sync {
            saveFileIndexToDisk([])
        }
    }

    /// 生成最近文件索引的 system prompt 片段
    func recentFilesPromptSection(limit: Int = 10) -> String {
        let entries = recentFileIndexEntries(limit: limit)
        guard !entries.isEmpty else { return "" }
        let lines = entries.map { entry in
            let project = entry.projectPath ?? ""
            return "- \(entry.title)（\(entry.path)）\(project.isEmpty ? "" : " [项目: \(project)]")\n  摘要：\(entry.summary)"
        }
        return "最近编辑的文件（当用户询问历史文件/项目时参考）：\n" + lines.joined(separator: "\n")
    }

    /// 格式化文件索引条目为可读文本
    func formatFileIndexEntries(_ entries: [FileIndexEntry]) -> String {
        guard !entries.isEmpty else { return "未找到匹配文件。" }
        let lines = entries.map { entry in
            """
            文件：\(entry.path)
            标题：\(entry.title)
            摘要：\(entry.summary)
            标签：\(entry.tags.isEmpty ? "无" : entry.tags.joined(separator: ", "))
            字数：\(entry.wordCount) | 最后打开：\(Self.formatDate(entry.lastOpenedAt))
            """
        }
        return lines.joined(separator: "\n---\n")
    }

    // MARK: - 交互推断

    /// 根据一次用户与 AI 的对话内容，启发式地更新用户画像
    func recordInteraction(userMessage: String, assistantMessage: String?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var profile = self.loadUserProfile()
            let lowercased = userMessage.lowercased()

            // 语言推断
            if userMessage.containsChineseCharacters {
                if !profile.writingStyle.contains("中文") {
                    profile.writingStyle += profile.writingStyle.isEmpty ? "使用中文" : "；使用中文"
                }
            } else {
                if !profile.writingStyle.contains("英文") {
                    profile.writingStyle += profile.writingStyle.isEmpty ? "使用英文" : "；使用英文"
                }
            }

            // 回答深度推断
            if userMessage.count > 200 {
                if !profile.behaviorNorms.contains("详细") {
                    profile.behaviorNorms += profile.behaviorNorms.isEmpty ? "用户倾向于详细、深入的说明" : "；用户倾向于详细、深入的说明"
                }
            } else if userMessage.count < 50 {
                if !profile.behaviorNorms.contains("简洁") {
                    profile.behaviorNorms += profile.behaviorNorms.isEmpty ? "用户倾向于简洁回复" : "；用户倾向于简洁回复"
                }
            }

            // 常见任务类型
            let taskKeywords: [(String, String)] = [
                ("总结", "偏好对内容进行总结/摘要"),
                ("摘要", "偏好对内容进行总结/摘要"),
                ("翻译", "经常需要翻译"),
                ("润色", "重视文字润色与表达优化"),
                ("扩写", "经常需要扩写或补充细节"),
                ("精简", "经常需要精简内容"),
                ("代码", "关注代码实现"),
                ("swift", "关注 Swift / Apple 生态"),
                ("python", "关注 Python 开发"),
                ("论文", "处理学术/论文内容"),
                ("研究", "处理研究类内容"),
                ("产品", "处理产品/需求文档"),
                ("博客", "撰写博客/文章"),
            ]
            for (keyword, habit) in taskKeywords where lowercased.contains(keyword) {
                if !profile.inferredHabits.contains(habit) {
                    profile.inferredHabits.append(habit)
                }
            }

            // 研究类型
            let researchKeywords: [(String, String)] = [
                ("代码", "编程/技术文档"),
                ("swift", "编程/技术文档"),
                ("python", "编程/技术文档"),
                ("论文", "学术研究"),
                ("研究", "学术研究"),
                ("产品", "产品需求"),
                ("需求", "产品需求"),
                ("博客", "内容创作"),
                ("文章", "内容创作"),
                ("翻译", "翻译/本地化"),
            ]
            for (keyword, type) in researchKeywords where lowercased.contains(keyword) {
                if !profile.researchTypes.contains(type) {
                    profile.researchTypes.append(type)
                }
            }

            // 工作习惯
            if lowercased.contains("@(" ) || lowercased.contains(" @") {
                if !profile.workHabits.contains("引用") {
                    profile.workHabits += profile.workHabits.isEmpty ? "习惯使用 @path 引用本地文件" : "；习惯使用 @path 引用本地文件"
                }
            }

            // 用户明确提出的规范
            if let assistant = assistantMessage, assistant.count > 100 {
                // 仅作占位，未来可扩展为从 AI 回复中提取用户反馈
            }

            profile.updatedAt = Date()
            self.saveUserProfile(profile)
        }
    }

    /// 允许 AI 或用户显式记录一条记忆
    func recordMemory(category: String, content: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var profile = self.loadUserProfile()
            let lowerCategory = category.lowercased()
            switch lowerCategory {
            case "writing_style", "style":
                profile.writingStyle += profile.writingStyle.isEmpty ? content : "；\(content)"
            case "behavior_norm", "behavior", "norm":
                profile.behaviorNorms += profile.behaviorNorms.isEmpty ? content : "；\(content)"
            case "habit":
                if !profile.inferredHabits.contains(content) {
                    profile.inferredHabits.append(content)
                }
            case "research_type", "research":
                if !profile.researchTypes.contains(content) {
                    profile.researchTypes.append(content)
                }
            case "work_habit", "work":
                profile.workHabits += profile.workHabits.isEmpty ? content : "；\(content)"
            default:
                profile.customNotes += profile.customNotes.isEmpty ? content : "\n\(content)"
            }
            profile.updatedAt = Date()
            self.saveUserProfile(profile)
        }
    }

    // MARK: - 本地摘要

    private func summarize(text: String, path: String) -> (title: String, summary: String, tags: [String], wordCount: Int) {
        let lines = text.components(separatedBy: .newlines)
        let firstNonEmptyLine = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let title = firstNonEmptyLine
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            .isEmpty ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : firstNonEmptyLine
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)

        let plain = text
            .replacingOccurrences(of: #"```[a-zA-Z0-9]*\n"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"```"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let summary = String(plain.prefix(200))

        var tags: [String] = []
        let headingRegex = try? NSRegularExpression(pattern: #"^#{1,6}\s+(.+)$"#, options: [])
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = headingRegex?.firstMatch(in: line, options: [], range: range),
               let range = Range(match.range(at: 1), in: line) {
                let heading = String(line[range]).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty, heading.count <= 40 {
                    tags.append(heading)
                }
            }
        }
        // 代码块语言
        let codeFenceRegex = try? NSRegularExpression(pattern: #"^```([a-zA-Z0-9+#_-]+)"#, options: [])
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = codeFenceRegex?.firstMatch(in: line, options: [], range: range),
               let range = Range(match.range(at: 1), in: line) {
                let lang = String(line[range])
                if !tags.contains(lang) {
                    tags.append(lang)
                }
            }
        }

        let countableText = text
            .replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^```[^\n]*$"#, with: "", options: .regularExpression)
        let wordCount = countableText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
        return (title, summary, Array(tags.prefix(15)), wordCount)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private var defaultMemoryTemplate: String {
        """
        # AI 核心记忆

        在这里记录你的编辑偏好、写作风格、常用术语、项目背景等。
        每次对话时，这些内容会作为上下文注入给 AI。

        ## 示例

        - 我喜欢用中文撰写技术文档，风格简洁。
        - 代码块使用 Swift 语法高亮。
        - 标题层级不超过三级。
        """
    }
}

extension String {
    fileprivate var containsChineseCharacters: Bool {
        unicodeScalars.contains { $0.properties.isIdeographic }
    }
}
