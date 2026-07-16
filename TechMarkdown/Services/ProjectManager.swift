import Foundation
import Combine
import UniformTypeIdentifiers

/// 项目节点模型
struct Project: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let rootURL: URL
}

/// 项目中的文件/目录条目
struct ProjectFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let path: String
    let isDirectory: Bool
    let depth: Int
    let contentType: UTType?

    var isTextLike: Bool {
        if isDirectory { return false }
        let ext = url.pathExtension.lowercased()
        let textExtensions: Set<String> = ["md", "markdown", "txt", "text", "tex", "swift", "py", "js", "ts", "json", "yml", "yaml", "xml", "html", "css", "sh"]
        if textExtensions.contains(ext) { return true }
        if let type = contentType {
            return type == .plainText || type == .markdown || type.conforms(to: .sourceCode) || type.conforms(to: .xml)
        }
        return false
    }
}

enum ProjectManagerError: Error, LocalizedError {
    case bookmarkCreationFailed
    case accessDenied
    case invalidPath
    case readFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .bookmarkCreationFailed:
            return "无法为目录创建安全书签"
        case .accessDenied:
            return "没有权限访问该目录或文件"
        case .invalidPath:
            return "路径无效"
        case .readFailed(let msg):
            return "读取失败: \(msg)"
        }
    }
}

/// 管理项目根目录、安全书签与项目文件枚举
final class ProjectManager {
    static let shared = ProjectManager()
    
    private let legacyProjectBookmarksKey = "techmarkdown.projectRootBookmarks"
    private let projectBookmarksKey = "techmarkdown.projectDirectoryBookmarks"
    private let fileBookmarksKey = "techmarkdown.fileRootBookmarks"
    private let recentFileBookmarksKey = "techmarkdown.recentFileBookmarks"
    private let queue = DispatchQueue(label: "com.techmarkdown.project-manager", qos: .userInitiated)
    
    @Published private(set) var projectRoots: [URL] = []
    @Published private(set) var fileRoots: [URL] = []
    
    private init() {
        loadProjectRoots()
        loadFileRoots()
        migrateLegacyProjectBookmarksIfNeeded()
        // 如果没有任何根目录，默认尝试将当前工作目录作为根目录
        if projectRoots.isEmpty, let cwd = URL(string: "file://" + FileManager.default.currentDirectoryPath) {
            _ = try? addProjectRoot(cwd)
        }
    }

    /// 仅用于测试：清空内存中的项目根、文件根与持久化的书签数据。
    /// 注意：这不会删除磁盘上的文件，仅重置书签列表。
    func resetForTesting() {
        projectRoots.removeAll()
        fileRoots.removeAll()
        UserDefaults.standard.removeObject(forKey: projectBookmarksKey)
        UserDefaults.standard.removeObject(forKey: fileBookmarksKey)
    }

    /// 将旧版“项目根目录”书签迁移为“项目文件夹”书签
    private func migrateLegacyProjectBookmarksIfNeeded() {
        let existing = UserDefaults.standard.array(forKey: projectBookmarksKey) as? [Data] ?? []
        guard existing.isEmpty else { return }

        let legacy = UserDefaults.standard.array(forKey: legacyProjectBookmarksKey) as? [Data] ?? []
        guard !legacy.isEmpty else { return }

        var migrated: [Data] = []
        for data in legacy {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), !isStale else { continue }
            migrated.append(data)
            if !projectRoots.contains(url) {
                projectRoots.append(url)
            }
        }
        UserDefaults.standard.set(migrated, forKey: projectBookmarksKey)
    }
    
    // MARK: - 项目根目录管理
    
    @discardableResult
    func addProjectRoot(_ url: URL) throws -> Bool {
        let directoryURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        guard directoryURL.isFileURL else {
            throw ProjectManagerError.invalidPath
        }
        
        // 先尝试访问资源以创建书签
        let didStart = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                directoryURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let bookmarkData = try directoryURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        var bookmarks = UserDefaults.standard.array(forKey: projectBookmarksKey) as? [Data] ?? []
        // 去重
        if bookmarks.contains(bookmarkData) {
            return false
        }
        bookmarks.append(bookmarkData)
        UserDefaults.standard.set(bookmarks, forKey: projectBookmarksKey)
        
        if !projectRoots.contains(directoryURL) {
            projectRoots.append(directoryURL)
        }
        return true
    }
    
    func removeProjectRoot(_ url: URL) {
        projectRoots.removeAll { $0 == url }
        persistProjectRoots()
    }
    
    private func loadProjectRoots() {
        projectRoots = loadBookmarks(forKey: projectBookmarksKey)
    }
    
    private func persistProjectRoots() {
        persistBookmarks(projectRoots, forKey: projectBookmarksKey)
    }
    
    // MARK: - 文件根目录管理
    
    @discardableResult
    func addFileRoot(_ url: URL) throws -> Bool {
        let directoryURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        guard directoryURL.isFileURL else {
            throw ProjectManagerError.invalidPath
        }
        
        let didStart = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                directoryURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let bookmarkData = try directoryURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        var bookmarks = UserDefaults.standard.array(forKey: fileBookmarksKey) as? [Data] ?? []
        if bookmarks.contains(bookmarkData) {
            return false
        }
        bookmarks.append(bookmarkData)
        UserDefaults.standard.set(bookmarks, forKey: fileBookmarksKey)
        
        if !fileRoots.contains(directoryURL) {
            fileRoots.append(directoryURL)
        }
        return true
    }
    
    func removeFileRoot(_ url: URL) {
        fileRoots.removeAll { $0 == url }
        persistFileRoots()
    }
    
    func listFileRoots() -> [Project] {
        fileRoots.map { Project(name: $0.lastPathComponent, url: $0, rootURL: $0) }
    }
    
    private func loadFileRoots() {
        fileRoots = loadBookmarks(forKey: fileBookmarksKey)
    }
    
    private func persistFileRoots() {
        persistBookmarks(fileRoots, forKey: fileBookmarksKey)
    }
    
    // MARK: - 书签辅助
    
    private func loadBookmarks(forKey key: String) -> [URL] {
        let bookmarks = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        var urls: [URL] = []
        for data in bookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if !isStale {
                    urls.append(url)
                }
            } catch {
                // 书签过期或无效，跳过
            }
        }
        return urls
    }
    
    private func persistBookmarks(_ urls: [URL], forKey key: String) {
        var bookmarks: [Data] = []
        for url in urls {
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks.append(data)
            }
        }
        UserDefaults.standard.set(bookmarks, forKey: key)
    }
    
    // MARK: - 项目枚举
    
    /// 列出所有项目。每个项目即一个被书签持久化的文件夹。
    func listProjects() -> [Project] {
        projectRoots.map { Project(name: $0.lastPathComponent, url: $0, rootURL: $0) }
    }

    /// 创建新项目：在 parentURL 下创建名为 name 的文件夹，并添加为项目书签
    func createProject(at url: URL) throws -> Project {
        guard url.isFileURL else {
            throw ProjectManagerError.invalidPath
        }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists {
            if !isDirectory.boolValue {
                throw ProjectManagerError.invalidPath
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
        }

        _ = try addProjectRoot(url)
        return Project(name: url.lastPathComponent, url: url, rootURL: url)
    }

    /// 导入已有文件夹作为项目
    func importProject(from url: URL) throws -> Project {
        let directoryURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        _ = try addProjectRoot(directoryURL)
        return Project(name: directoryURL.lastPathComponent, url: directoryURL, rootURL: directoryURL)
    }

    /// 在项目目录下创建空文件
    func createFile(in projectURL: URL, named: String) throws -> URL {
        let url = projectURL.appendingPathComponent(named)
        try access(projectURL) {
            guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil) else {
                throw ProjectManagerError.readFailed("无法创建文件")
            }
        }
        return url
    }

    /// 在项目目录下创建子文件夹
    func createFolder(in projectURL: URL, named: String) throws -> URL {
        let url = projectURL.appendingPathComponent(named)
        try access(projectURL) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
        }
        return url
    }
    
    /// 递归列出项目内的文件/目录，默认最大深度 2
    func listFiles(in project: Project, maxDepth: Int = 2) -> [ProjectFile] {
        listFiles(inDirectory: project.url, maxDepth: maxDepth)
    }
    
    /// 递归列出任意目录内的文件/目录
    func listFiles(inDirectory directoryURL: URL, maxDepth: Int = 2) -> [ProjectFile] {
        var results: [ProjectFile] = []
        access(directoryURL) {
            enumerate(url: directoryURL, depth: 0, maxDepth: maxDepth, into: &results)
        }
        return results.sorted { $0.path < $1.path }
    }
    
    private func enumerate(url: URL, depth: Int, maxDepth: Int, into results: inout [ProjectFile]) {
        guard depth <= maxDepth else { return }
        
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        
        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let contentType = UTType(filenameExtension: item.pathExtension)
            
            results.append(ProjectFile(
                name: item.lastPathComponent,
                url: item,
                path: item.path,
                isDirectory: isDirectory,
                depth: depth,
                contentType: contentType
            ))
            
            if isDirectory {
                enumerate(url: item, depth: depth + 1, maxDepth: maxDepth, into: &results)
            }
        }
    }
    
    // MARK: - 文件读取
    
    /// 读取项目内文本文件内容，最大长度默认 100,000
    func readFile(at path: String, maxLength: Int = 100_000) async throws -> String {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectManagerError.invalidPath
        }
        
        return try access(url) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let text = String(data: data.prefix(maxLength), encoding: .utf8)
                ?? String(data: data.prefix(maxLength), encoding: .ascii)
                ?? ""
            return text
        }
    }
    
    // MARK: - Security Scoped Resource 访问封装
    
    /// 同步访问 security-scoped 资源
    @discardableResult
    func accessSecurityScopedResource<T>(at path: String, block: () throws -> T) rethrows -> T {
        let url = URL(fileURLWithPath: path)
        return try access(url, block: block)
    }
    
    /// 异步访问 security-scoped 资源
    @discardableResult
    func accessAsync<T>(_ url: URL, block: () async throws -> T) async rethrows -> T {
        let scopedURL = findScopedRoot(for: url) ?? url
        let didStart = scopedURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                scopedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try await block()
    }
    
    @discardableResult
    private func access<T>(_ url: URL, block: () throws -> T) rethrows -> T {
        let scopedURL = findScopedRoot(for: url) ?? url
        let didStart = scopedURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                scopedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try block()
    }
    
    /// 返回包含该 URL 的已授权根目录（项目根或文件根）
    func scopedRoot(for url: URL) -> URL? {
        findScopedRoot(for: url)
    }

    // MARK: - 单个文件安全书签

    /// 为指定文件创建安全书签并持久化，以便后续从「最近文件」中重新访问。
    /// 应在应用已获得该文件访问权限时调用（如通过 NSOpenPanel / NSSavePanel）。
    func bookmarkFile(_ url: URL) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return }

            var bookmarks = UserDefaults.standard.dictionary(forKey: self.recentFileBookmarksKey) as? [String: Data] ?? [:]
            bookmarks[url.path] = data
            UserDefaults.standard.set(bookmarks, forKey: self.recentFileBookmarksKey)
        }
    }

    /// 根据文件路径解析之前保存的安全书签。
    /// 返回值可直接用于 `startAccessingSecurityScopedResource()`。
    func resolveBookmarkedFileURL(_ path: String) -> URL? {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: recentFileBookmarksKey) as? [String: Data],
              let data = bookmarks[path] else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            removeFileBookmark(for: path)
            return nil
        }
        return url
    }

    /// 移除指定路径的文件书签（例如书签已过期）
    func removeFileBookmark(for path: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var bookmarks = UserDefaults.standard.dictionary(forKey: self.recentFileBookmarksKey) as? [String: Data] ?? [:]
            bookmarks.removeValue(forKey: path)
            UserDefaults.standard.set(bookmarks, forKey: self.recentFileBookmarksKey)
        }
    }

    /// 查找包含该 URL 的已授权根目录（项目根或文件根）
    private func findScopedRoot(for url: URL) -> URL? {
        let targetPath = url.resolvingSymlinksInPath().path
        for root in (projectRoots + fileRoots) {
            let rootPath = root.resolvingSymlinksInPath().path
            if targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") {
                return root
            }
        }
        return nil
    }
}
