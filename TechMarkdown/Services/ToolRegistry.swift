import Foundation

final class ToolRegistry {
    static let shared = ToolRegistry()
    private var tools: [String: ToolExecutable] = [:]
    
    private init() {
        registerBuiltInTools()
    }
    
    var allDefinitions: [ToolDefinition] {
        Array(tools.values.map(\.definition))
    }
    
    func register(_ tool: ToolExecutable) {
        tools[tool.definition.name] = tool
    }
    
    func execute(toolCall: ToolCall) async -> ToolResult {
        guard let tool = tools[toolCall.function.name] else {
            return ToolResult(
                toolCallID: toolCall.id,
                name: toolCall.function.name,
                output: "未找到工具: \(toolCall.function.name)",
                isError: true
            )
        }
        
        do {
            guard let data = toolCall.function.arguments.data(using: .utf8),
                  let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ToolResult(
                    toolCallID: toolCall.id,
                    name: toolCall.function.name,
                    output: "无法解析工具参数",
                    isError: true
                )
            }
            
            let output = try await tool.execute(arguments: arguments)
            return ToolResult(toolCallID: toolCall.id, name: toolCall.function.name, output: output)
        } catch {
            return ToolResult(
                toolCallID: toolCall.id,
                name: toolCall.function.name,
                output: "工具执行错误: \(error.localizedDescription)",
                isError: true
            )
        }
    }
    
    private func registerBuiltInTools() {
        register(ReadFileTool())
        register(ListDirectoryTool())
        register(SearchInDocumentTool())
        register(WebSearchTool())
        register(WebReadTool())
        register(ApplyMarkdownEditTool())
        register(ApplyTextEditTool())
        register(QueryUserMemoryTool())
        register(SearchFileIndexTool())
        register(RecordMemoryTool())
        register(ListProjectFilesTool())
        register(ReadProjectFileTool())
        register(AddProjectFileToContextTool())
        register(QueryProjectDocumentsTool())
    }
}

// MARK: - Built-in Tools

final class ReadFileTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "read_file",
        description: "读取本地文件的内容，支持 Markdown、文本、代码文件等。路径支持 ~/ 简写。",
        parameters: [
            ToolParameter(name: "path", type: "string", description: "文件的绝对路径或相对于用户主目录的路径")
        ],
        requiredParameters: ["path"]
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw FileContextError.readFailed("缺少 path 参数")
        }
        return try await FileContextService.shared.readFile(at: path)
    }
}

final class ListDirectoryTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "list_directory",
        description: "列出指定目录下的文件和文件夹，帮助用户浏览本地文件。",
        parameters: [
            ToolParameter(name: "path", type: "string", description: "目录路径，支持 ~/ 简写")
        ],
        requiredParameters: ["path"]
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw FileContextError.readFailed("缺少 path 参数")
        }
        return try await FileContextService.shared.listDirectory(at: path)
    }
}

final class SearchInDocumentTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "search_in_document",
        description: "在当前 Markdown 文档中搜索关键词或正则表达式，返回匹配的行号与上下文。",
        parameters: [
            ToolParameter(name: "query", type: "string", description: "要搜索的关键词或正则表达式"),
            ToolParameter(name: "case_sensitive", type: "boolean", description: "是否区分大小写，默认 false")
        ],
        requiredParameters: ["query"]
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return "请提供搜索关键词"
        }
        
        // 通过 NotificationCenter 获取当前文档内容（ToolRegistry 无法直接持有文档）
        let documentText = NotificationCenter.default.currentDocumentText
        let lines = documentText.components(separatedBy: .newlines)
        let caseSensitive = arguments["case_sensitive"] as? Bool ?? false
        
        var results: [String] = []
        for (index, line) in lines.enumerated() {
            let compareLine = caseSensitive ? line : line.lowercased()
            let compareQuery = caseSensitive ? query : query.lowercased()
            if compareLine.contains(compareQuery) {
                results.append("行 \(index + 1): \(line)")
            }
        }
        
        return results.isEmpty ? "未找到匹配内容" : results.joined(separator: "\n")
    }
}

final class WebSearchTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "web_search",
        description: "使用 DuckDuckGo 搜索引擎查询互联网公开信息，返回相关网页的标题、链接和摘要。当用户询问最新资讯、事实核查或需要外部资料时使用。",
        parameters: [
            ToolParameter(name: "query", type: "string", description: "搜索关键词或问题")
        ],
        requiredParameters: ["query"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return "请提供搜索关键词"
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return "搜索 URL 无效"
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return "搜索请求失败"
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        return parseResults(from: html)
    }

    private func parseResults(from html: String) -> String {
        let pattern = #"(?s)<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>.*?<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return "无法解析搜索结果"
        }

        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        var results: [String] = []
        for (index, match) in matches.prefix(5).enumerated() {
            let link = extract(html, at: match.range(at: 1))
            let title = stripHTML(extract(html, at: match.range(at: 2)))
            let snippet = stripHTML(extract(html, at: match.range(at: 3)))
            results.append("\(index + 1). [\(title)](\(link))\n\(snippet)")
        }

        return results.isEmpty ? "未找到相关结果" : results.joined(separator: "\n\n")
    }

    private func extract(_ html: String, at range: NSRange) -> String {
        guard let range = Range(range, in: html) else { return "" }
        return String(html[range])
    }

    private func stripHTML(_ string: String) -> String {
        var result = string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
        let entities = [
            "&quot;": "\"", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&#39;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class WebReadTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "web_read",
        description: "读取指定网页的完整正文内容，返回去除 HTML 标签后的文本。供 AI 在搜索后深入了解网页详情。",
        parameters: [
            ToolParameter(name: "url", type: "string", description: "要读取的网页 URL")
        ],
        requiredParameters: ["url"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let urlString = arguments["url"] as? String,
              let url = URL(string: urlString) else {
            return "URL 无效"
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return "网页请求失败"
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        return extractText(from: html)
    }

    private func extractText(from html: String) -> String {
        // 先用 NSAttributedString 把 HTML 转成可读文本
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else {
            return stripHTMLTags(html)
        }

        let lines = attributed.string.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? "网页正文为空" : String(text.prefix(12000))
    }

    private func stripHTMLTags(_ string: String) -> String {
        var result = string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
        let entities = [
            "&quot;": "\"", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&#39;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class ApplyMarkdownEditTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "apply_markdown_edit",
        description: "将修改后的完整 Markdown 文本应用到当前 Markdown 文档。调用后用户可在侧边栏确认是否接受。",
        parameters: [
            ToolParameter(name: "markdown", type: "string", description: "完整的修改后 Markdown 文本"),
            ToolParameter(name: "reason", type: "string", description: "修改原因或说明")
        ],
        requiredParameters: ["markdown", "reason"]
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        guard let markdown = arguments["markdown"] as? String else {
            return "缺少 markdown 参数"
        }
        let reason = arguments["reason"] as? String ?? "AI 建议的修改"
        
        // 发布一个待处理编辑通知，由主界面捕获并展示确认面板
        NotificationCenter.default.post(
            name: .pendingMarkdownEdit,
            object: nil,
            userInfo: [
                "markdown": markdown,
                "reason": reason
            ]
        )
        
        return "修改建议已生成，等待用户在侧边栏确认。"
    }
}

final class ApplyTextEditTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "apply_text_edit",
        description: "将修改后的完整文本应用到当前文档。适用于 Markdown、LaTeX 等纯文本文档；调用后用户可在侧边栏确认是否接受。",
        parameters: [
            ToolParameter(name: "text", type: "string", description: "完整的修改后文本"),
            ToolParameter(name: "reason", type: "string", description: "修改原因或说明")
        ],
        requiredParameters: ["text", "reason"]
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        guard let text = arguments["text"] as? String else {
            return "缺少 text 参数"
        }
        let reason = arguments["reason"] as? String ?? "AI 建议的修改"
        
        NotificationCenter.default.post(
            name: .pendingTextEdit,
            object: nil,
            userInfo: [
                "text": text,
                "reason": reason
            ]
        )
        
        return "修改建议已生成，等待用户在侧边栏确认。"
    }
}

// MARK: - Memory Tools

final class QueryUserMemoryTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "query_user_memory",
        description: "查询 AI 记忆系统中保存的用户画像、写作风格、行为习惯、研究类型、工作习惯以及最近编辑的文件索引。",
        parameters: [
            ToolParameter(name: "query", type: "string", description: "可选的过滤关键词，用于检索相关记忆或文件")
        ],
        requiredParameters: []
    )

    func execute(arguments: [String: Any]) async throws -> String {
        let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = MemoryService.shared.loadUserProfile()
        let recentFiles = MemoryService.shared.recentFileIndexEntries(limit: 10)
        var parts: [String] = []

        if !profile.promptSection.isEmpty {
            parts.append("【用户画像】\n\(profile.promptSection)")
        } else {
            parts.append("【用户画像】\n暂无明确记录。")
        }

        if !query.isEmpty {
            let matches = MemoryService.shared.searchFileIndex(query: query)
            if matches.isEmpty {
                parts.append("\n【历史文件搜索】\n未找到与“\(query)”相关的历史文件。")
            } else {
                parts.append("\n【历史文件搜索：\(query)】\n\(MemoryService.shared.formatFileIndexEntries(matches))")
            }
        }

        if !recentFiles.isEmpty {
            parts.append("\n【最近编辑文件】\n\(MemoryService.shared.formatFileIndexEntries(recentFiles))")
        }

        return parts.joined(separator: "\n")
    }
}

final class SearchFileIndexTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "search_file_index",
        description: "按关键词搜索用户历史编辑过的文件/项目，返回文件路径和摘要。",
        parameters: [
            ToolParameter(name: "query", type: "string", description: "搜索关键词，可匹配文件名、路径、标题、摘要或标签")
        ],
        requiredParameters: ["query"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return "请提供搜索关键词"
        }
        let matches = MemoryService.shared.searchFileIndex(query: query)
        return MemoryService.shared.formatFileIndexEntries(matches)
    }
}

final class RecordMemoryTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "record_memory",
        description: "记录一条关于用户偏好、习惯或行为规范的显式记忆。仅在用户明确要求记住某事时调用。",
        parameters: [
            ToolParameter(name: "category", type: "string", description: "记忆类别：writing_style / behavior_norm / habit / research_type / work_habit / note"),
            ToolParameter(name: "content", type: "string", description: "要记录的具体内容")
        ],
        requiredParameters: ["category", "content"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let category = arguments["category"] as? String, !category.isEmpty else {
            return "缺少 category 参数"
        }
        guard let content = arguments["content"] as? String, !content.isEmpty else {
            return "缺少 content 参数"
        }
        MemoryService.shared.recordMemory(category: category, content: content)
        return "已记录记忆：[\(category)] \(content)"
    }
}

extension Notification.Name {
    static let pendingMarkdownEdit = Notification.Name("pendingMarkdownEdit")
    static let pendingTextEdit = Notification.Name("pendingTextEdit")
}

extension NotificationCenter {
    var currentDocumentText: String {
        // 通过 UserDefaults 中转当前文档内容（简化实现）
        UserDefaults.standard.string(forKey: "techmarkdown.currentDocumentText") ?? ""
    }
}

// MARK: - Project & Document Retrieval Tools

final class ListProjectFilesTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "list_project_files",
        description: "列出项目中的文件和目录。如果不传参数，返回所有项目根目录和项目列表。",
        parameters: [
            ToolParameter(name: "project_path", type: "string", description: "项目目录的绝对路径"),
            ToolParameter(name: "directory_path", type: "string", description: "任意目录的绝对路径，用于浏览子目录"),
            ToolParameter(name: "max_depth", type: "integer", description: "递归最大深度，默认 2")
        ],
        requiredParameters: []
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        let maxDepth = (arguments["max_depth"] as? Int) ?? 2
        
        if let dirPath = arguments["directory_path"] as? String, !dirPath.isEmpty {
            let files = ProjectManager.shared.listFiles(inDirectory: URL(fileURLWithPath: dirPath), maxDepth: maxDepth)
            return formatFiles(files)
        }
        
        if let projectPath = arguments["project_path"] as? String, !projectPath.isEmpty {
            let projects = ProjectManager.shared.listProjects()
            guard let project = projects.first(where: { $0.url.path == projectPath }) else {
                return "未找到项目: \(projectPath)"
            }
            let files = ProjectManager.shared.listFiles(in: project, maxDepth: maxDepth)
            return formatFiles(files)
        }
        
        let projects = ProjectManager.shared.listProjects()
        if projects.isEmpty {
            return "当前没有已加载的项目。请使用项目浏览器添加项目根目录。"
        }
        return "项目列表：\n" + projects.map { "- \($0.url.path) (\($0.name))" }.joined(separator: "\n")
    }
    
    private func formatFiles(_ files: [ProjectFile]) -> String {
        if files.isEmpty { return "目录为空或无法访问。" }
        return files.map { file in
            let indent = String(repeating: "  ", count: file.depth)
            let icon = file.isDirectory ? "📁" : "📄"
            return "\(indent)\(icon) \(file.name)"
        }.joined(separator: "\n")
    }
}

final class ReadProjectFileTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "read_project_file",
        description: "读取项目内文件的内容，自动解析 Markdown、文本、PDF、DOCX 等格式。",
        parameters: [
            ToolParameter(name: "path", type: "string", description: "文件的绝对路径"),
            ToolParameter(name: "max_length", type: "integer", description: "最大返回字符数，默认 50,000")
        ],
        requiredParameters: ["path"]
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            return "缺少 path 参数"
        }
        let maxLength = (arguments["max_length"] as? Int) ?? 50_000
        do {
            let text = try await DocumentRetrievalService.shared.extractText(from: path, maxLength: maxLength)
            return text.isEmpty ? "文件内容为空" : text
        } catch {
            return "读取失败: \(error.localizedDescription)"
        }
    }
}

final class AddProjectFileToContextTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "add_project_file_to_context",
        description: "将项目中的文件加入当前 AI 对话的引用上下文。",
        parameters: [
            ToolParameter(name: "path", type: "string", description: "要加入上下文的文件绝对路径")
        ],
        requiredParameters: ["path"]
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            return "缺少 path 参数"
        }
        NotificationCenter.default.post(
            name: .addProjectFileToContext,
            object: nil,
            userInfo: ["path": path]
        )
        return "已将文件加入上下文: \(path)"
    }
}

final class QueryProjectDocumentsTool: ToolExecutable {
    let definition = ToolDefinition(
        name: "query_project_documents",
        description: "基于本地 TF-IDF 索引对项目文档进行语义/关键词混合检索，返回相关文件路径和摘要。",
        parameters: [
            ToolParameter(name: "query", type: "string", description: "自然语言查询或关键词"),
            ToolParameter(name: "top_k", type: "integer", description: "返回结果数量，默认 5")
        ],
        requiredParameters: ["query"]
    )
    
    func execute(arguments: [String: Any]) async throws -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return "请提供查询内容"
        }
        let topK = (arguments["top_k"] as? Int) ?? 5
        await DocumentRetrievalService.shared.ensureIndexed()
        let results = DocumentRetrievalService.shared.search(query: query, topK: topK)
        if results.isEmpty {
            return "未找到与“\(query)”相关的项目文档。请先使用 list_project_files 确认文件已被索引，或使用项目浏览器触发索引。"
        }
        return results.enumerated().map { index, result in
            """
            \(index + 1). \(result.path) (score: \(String(format: "%.3f", result.score)))
            \(result.snippet.isEmpty ? "(无摘要)" : result.snippet.prefix(300))
            """
        }.joined(separator: "\n\n")
    }
}

extension Notification.Name {
    static let addProjectFileToContext = Notification.Name("addProjectFileToContext")
}
