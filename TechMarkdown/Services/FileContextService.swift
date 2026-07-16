import Foundation

enum FileContextError: Error, LocalizedError {
    case accessDenied
    case fileNotFound
    case readFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .accessDenied: return "没有权限访问该文件"
        case .fileNotFound: return "文件不存在"
        case .readFailed(let msg): return "读取失败: \(msg)"
        }
    }
}

final class FileContextService {
    static let shared = FileContextService()
    private init() {}
    
    /// 解析用户输入中的 @path 引用，返回 (cleanText, referencedPaths)
    func extractFileReferences(from text: String) -> (cleanText: String, paths: [String]) {
        let pattern = #"@\(([^)]+)\)|@([^\s\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (text, [])
        }
        
        var paths: [String] = []
        let mutableText = NSMutableString(string: text)
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        
        for match in matches.reversed() {
            let fullRange = match.range(at: 0)
            let parenRange = match.range(at: 1)
            let bareRange = match.range(at: 2)
            
            let path: String
            if parenRange.location != NSNotFound, let range = Range(parenRange, in: text) {
                path = String(text[range])
            } else if bareRange.location != NSNotFound, let range = Range(bareRange, in: text) {
                path = String(text[range])
            } else {
                continue
            }
            
            paths.append(path)
            mutableText.replaceCharacters(in: fullRange, with: "")
        }
        
        return (String(mutableText), paths)
    }
    
    func readFile(at path: String, maxLength: Int = 100_000) async throws -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url: URL
        if expandedPath.hasPrefix("/") {
            url = URL(fileURLWithPath: expandedPath)
        } else {
            url = URL(fileURLWithPath: expandedPath, relativeTo: FileManager.default.homeDirectoryForCurrentUser)
        }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileContextError.fileNotFound
        }
        
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw FileContextError.accessDenied
        }
        
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let text = String(data: data.prefix(maxLength), encoding: .utf8)
                ?? String(data: data.prefix(maxLength), encoding: .ascii)
                ?? ""
            return text
        } catch {
            throw FileContextError.readFailed(error.localizedDescription)
        }
    }
    
    func listDirectory(at path: String, maxDepth: Int = 1) async throws -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileContextError.fileNotFound
        }
        
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        
        var lines: [String] = []
        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            lines.append("\(isDir ? "📁" : "📄") \(item.lastPathComponent)")
        }
        return lines.joined(separator: "\n")
    }
}
