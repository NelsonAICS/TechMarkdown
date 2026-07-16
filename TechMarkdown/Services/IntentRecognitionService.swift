import Foundation

/// 用户意图分类结果
enum UserIntent: String, CaseIterable {
    case chat                 // 普通聊天/无需工具
    case queryProjectDocs     // 检索项目文档
    case readProjectFile      // 读取项目内指定文件
    case addProjectFileToContext // 把项目文件加入上下文
    case editDocument         // 修改当前 Markdown 文档
    case webSearch            // 联网搜索
    case queryMemory          // 查询用户记忆/历史文件
    case recordMemory         // 记录用户偏好
    case unknown              // 不确定

    var displayName: String {
        switch self {
        case .chat: return "自由对话"
        case .queryProjectDocs: return "项目文档检索"
        case .readProjectFile: return "读取项目文件"
        case .addProjectFileToContext: return "引用项目文件"
        case .editDocument: return "编辑当前文档"
        case .webSearch: return "联网搜索"
        case .queryMemory: return "查询记忆"
        case .recordMemory: return "记录记忆"
        case .unknown: return "未知"
        }
    }

    /// 该意图下最可能用到的工具（用于工具排序/过滤）
    var preferredToolNames: [String] {
        switch self {
        case .chat:
            return []
        case .queryProjectDocs:
            return ["query_project_documents", "list_project_files", "read_project_file"]
        case .readProjectFile:
            return ["read_project_file", "list_project_files"]
        case .addProjectFileToContext:
            return ["add_project_file_to_context", "read_project_file", "list_project_files"]
        case .editDocument:
            return ["apply_markdown_edit", "search_in_document"]
        case .webSearch:
            return ["web_search", "web_read"]
        case .queryMemory:
            return ["query_user_memory", "search_file_index"]
        case .recordMemory:
            return ["record_memory"]
        case .unknown:
            return []
        }
    }
}

/// 意图识别结果
struct IntentClassification {
    let intent: UserIntent
    let confidence: Double
    let reason: String
    let preferredTools: [String]
}

/// 轻量级意图识别服务：规则启发 + LLM few-shot 分类
///
/// 设计原则：
/// 1. 先走低成本规则匹配，命中直接返回，避免每次请求都调用模型。
/// 2. 规则不确定时，再用 LLM 做 few-shot 结构化分类。
/// 3. 分类结果只影响工具排序/优先级，不强制屏蔽其他工具，降低误判成本。
final class IntentRecognitionService {
    static let shared = IntentRecognitionService()

    private init() {}

    /// 对用户消息进行意图分类
    /// - Parameters:
    ///   - text: 用户输入（已去除文件引用等噪音）
    ///   - documentText: 当前文档内容，可为空
    ///   - availableTools: 当前可用的工具定义，仅用于生成描述
    ///   - configuration: AI 配置
    ///   - apiKey: API Key
    /// - Returns: 分类结果
    func classify(
        text: String,
        documentText: String = "",
        availableTools: [ToolDefinition] = [],
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async -> IntentClassification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return IntentClassification(intent: .chat, confidence: 1.0, reason: "空消息", preferredTools: [])
        }

        // 1. 低成本规则启发
        if let heuristic = heuristicClassify(trimmed, documentText: documentText) {
            return heuristic
        }

        // 2. 规则不确定时，使用 LLM few-shot 分类
        return await llmClassify(
            text: trimmed,
            documentText: documentText,
            availableTools: availableTools,
            configuration: configuration,
            apiKey: apiKey
        )
    }

    // MARK: - 规则启发

    private func heuristicClassify(_ text: String, documentText: String) -> IntentClassification? {
        let lower = text.lowercased()

        // 记忆类意图通常非常明确
        if lower.contains("记住") || lower.contains("记下来") || lower.contains("以后记得") {
            return IntentClassification(intent: .recordMemory, confidence: 0.95, reason: "用户明确要求记录", preferredTools: UserIntent.recordMemory.preferredToolNames)
        }

        // 联网搜索
        let webKeywords = ["网上搜索", "搜一下", "google", "百度", "必应", "查一下网上", "联网", "web search"]
        if webKeywords.contains(where: { lower.contains($0) }) {
            return IntentClassification(intent: .webSearch, confidence: 0.9, reason: "包含联网搜索关键词", preferredTools: UserIntent.webSearch.preferredToolNames)
        }

        // 项目文档检索：包含“项目”+“搜索/检索/查找/查”
        let projectSearchPattern = ["项目", "文档", "文件"]
        let searchVerbs = ["搜索", "检索", "查找", "查", "找", "有没有", "哪些"]
        let hasProject = projectSearchPattern.contains(where: { lower.contains($0) })
        let hasSearchVerb = searchVerbs.contains(where: { lower.contains($0) })
        if hasProject && hasSearchVerb {
            return IntentClassification(intent: .queryProjectDocs, confidence: 0.85, reason: "项目+搜索关键词", preferredTools: UserIntent.queryProjectDocs.preferredToolNames)
        }

        // 读取项目文件：包含“打开/读取/查看”+ 路径或扩展名
        let readVerbs = ["打开", "读取", "查看", "读一下", "看一下"]
        let hasReadVerb = readVerbs.contains(where: { lower.contains($0) })
        let hasPath = text.contains("/") || text.contains("\\") || text.contains(".")
        if hasReadVerb && hasPath {
            return IntentClassification(intent: .readProjectFile, confidence: 0.85, reason: "读取+路径/文件名", preferredTools: UserIntent.readProjectFile.preferredToolNames)
        }

        // 引用文件到上下文
        let contextVerbs = ["加入上下文", "引用", "放到上下文", "一起分析"]
        if contextVerbs.contains(where: { lower.contains($0) }) && hasPath {
            return IntentClassification(intent: .addProjectFileToContext, confidence: 0.85, reason: "引用文件到上下文", preferredTools: UserIntent.addProjectFileToContext.preferredToolNames)
        }

        // 编辑当前文档
        let editVerbs = ["修改", "润色", "改写", "重写", "翻译", "生成目录", "添加", "删除", "更新", "改成", "调整为"]
        let docTargets = ["文档", "文章", "当前", "这段", "全文", "markdown", "正文"]
        let hasEditVerb = editVerbs.contains(where: { lower.contains($0) })
        let hasDocTarget = docTargets.contains(where: { lower.contains($0) }) || !documentText.isEmpty
        if hasEditVerb && hasDocTarget {
            return IntentClassification(intent: .editDocument, confidence: 0.8, reason: "修改文档意图", preferredTools: UserIntent.editDocument.preferredToolNames)
        }

        // 查询记忆/历史文件
        let memoryVerbs = ["我以前", "我之前", "我习惯", "我喜欢", "我最近", "我的偏好"]
        if memoryVerbs.contains(where: { lower.contains($0) }) {
            return IntentClassification(intent: .queryMemory, confidence: 0.75, reason: "涉及用户历史/偏好", preferredTools: UserIntent.queryMemory.preferredToolNames)
        }

        // 规则未命中，交给 LLM
        return nil
    }

    // MARK: - LLM 分类

    private func llmClassify(
        text: String,
        documentText: String,
        availableTools: [ToolDefinition],
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async -> IntentClassification {
        var config = configuration
        config.systemPrompt = classificationSystemPrompt(documentText: documentText, availableTools: availableTools)
        config.temperature = 0.0

        let userPrompt = "用户消息：\"\(text)\""
        let messages = [ChatMessage(role: .user, content: userPrompt)]

        do {
            let response = try await AIService.shared.chat(
                messages: messages,
                documentText: "",
                referencedFiles: [],
                selectedTextSnippets: [],
                tools: [],
                configuration: config,
                apiKey: apiKey
            )
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return parseClassification(content, fallbackReason: "LLM 分类")
        } catch {
            return IntentClassification(intent: .unknown, confidence: 0.0, reason: "分类失败: \(error.localizedDescription)", preferredTools: [])
        }
    }

    private func classificationSystemPrompt(documentText: String, availableTools: [ToolDefinition]) -> String {
        let toolList = availableTools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let intentList = UserIntent.allCases
            .filter { $0 != .unknown }
            .map { "- \($0.rawValue): \($0.displayName)" }
            .joined(separator: "\n")

        return """
        你是一个意图识别器。请根据用户消息判断其真实意图，并以 JSON 格式输出，不要输出任何额外解释。

        可选意图：
        \(intentList)

        当前可用工具：
        \(toolList)

        当前文档长度：\(documentText.count) 字符。

        输出格式（严格 JSON，reason 使用中文）：
        {
          "intent": "query_project_documents",
          "confidence": 0.92,
          "reason": "用户想在项目文档中查找某个主题"
        }

        规则：
        1. intent 必须是上面列出的 rawValue 之一。
        2. confidence 是 0 到 1 之间的数字。
        3. 如果用户只是打招呼、闲聊、不需要任何工具，请使用 "chat"。
        4. 如果用户想搜索项目里的文档/代码/笔记，请使用 "query_project_documents"。
        5. 如果用户想读取项目内某个具体文件，请使用 "read_project_file"。
        6. 如果用户想把某个项目文件加入当前上下文一起分析，请使用 "add_project_file_to_context"。
        7. 如果用户想修改、润色、翻译、续写当前 Markdown 文档，请使用 "edit_document"。
        8. 如果用户明确要求联网搜索，请使用 "web_search"。
        9. 如果用户询问自己的偏好、历史文件或工作习惯，请使用 "query_memory"。
        10. 如果用户要求记住某件事，请使用 "record_memory"。
        """
    }

    private func parseClassification(_ content: String, fallbackReason: String) -> IntentClassification {
        // 尝试提取 JSON 块
        let jsonString: String
        if let start = content.range(of: "{"), let end = content.range(of: "}", range: start.upperBound..<content.endIndex) {
            jsonString = String(content[start.lowerBound..<end.upperBound])
        } else {
            jsonString = content
        }

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return IntentClassification(intent: .unknown, confidence: 0.0, reason: "无法解析分类结果", preferredTools: [])
        }

        let intentRaw = json["intent"] as? String ?? "unknown"
        let confidence = (json["confidence"] as? Double) ?? 0.0
        let reason = (json["reason"] as? String) ?? fallbackReason

        let intent = UserIntent(rawValue: intentRaw) ?? .unknown
        return IntentClassification(
            intent: intent,
            confidence: confidence,
            reason: reason,
            preferredTools: intent.preferredToolNames
        )
    }
}
