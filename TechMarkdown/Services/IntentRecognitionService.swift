import Foundation

/// 工具路由意图。内容目标与是否允许修改文档由独立字段表达。
enum UserIntent: String, CaseIterable {
    case chat = "chat"                                // 普通聊天/只读文档任务
    case queryProjectDocs = "query_project_documents" // 检索项目文档
    case readProjectFile = "read_project_file"         // 读取项目内指定文件
    case addProjectFileToContext = "add_project_file_to_context"
    case editDocument = "edit_document"                // 生成当前文档修改建议
    case webSearch = "web_search"                      // 联网搜索
    case queryMemory = "query_memory"                  // 查询用户记忆/历史文件
    case recordMemory = "record_memory"                // 记录用户偏好
    case unknown = "unknown"                           // 不确定

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

/// 用户希望完成的内容任务。它不代表写入权限。
enum IntentGoal: String, CaseIterable {
    case converse
    case summarize
    case organize
    case explain
    case rewrite
    case translate
    case createOutline = "create_outline"
    case retrieve
    case searchWeb = "search_web"
    case queryMemory = "query_memory"
    case recordMemory = "record_memory"
    case unknown

    var displayName: String {
        switch self {
        case .converse: return "自由问答"
        case .summarize: return "总结文档"
        case .organize: return "梳理文档"
        case .explain: return "解释内容"
        case .rewrite: return "改写内容"
        case .translate: return "翻译内容"
        case .createOutline: return "生成提纲或目录"
        case .retrieve: return "检索资料"
        case .searchWeb: return "联网搜索"
        case .queryMemory: return "查询记忆"
        case .recordMemory: return "记录记忆"
        case .unknown: return "待确认"
        }
    }
}

enum IntentOutputDestination: String {
    case conversation
    case documentEditProposal = "document_edit_proposal"

    var displayName: String {
        switch self {
        case .conversation: return "对话中输出"
        case .documentEditProposal: return "生成待确认修改"
        }
    }
}

enum IntentMutationPolicy: String {
    case readOnly = "read_only"
    case proposeDocumentEdit = "propose_document_edit"

    var displayName: String {
        switch self {
        case .readOnly: return "只读，不修改原文"
        case .proposeDocumentEdit: return "允许生成修改建议，应用前仍需确认"
        }
    }
}

/// 从用户原话中提取的写入授权。模型不能自行扩大这项权限。
struct DocumentActionContract {
    let output: IntentOutputDestination
    let mutationPolicy: IntentMutationPolicy
    let evidence: [String]

    var allowsDocumentProposal: Bool {
        mutationPolicy == .proposeDocumentEdit
    }

    static func resolve(_ text: String) -> DocumentActionContract {
        let lower = text.lowercased()
        let readOnlySignals = [
            "不要修改", "别修改", "不修改", "不要改", "别改", "先别改",
            "只输出", "仅输出", "只回答", "在对话中", "在聊天中",
            "先给我看", "给我看效果", "不写回", "不要写回", "无需修改"
        ]
        if let signal = readOnlySignals.first(where: { lower.contains($0) }) {
            return DocumentActionContract(
                output: .conversation,
                mutationPolicy: .readOnly,
                evidence: [signal]
            )
        }

        let explicitWriteSignals = [
            "写回文档", "写入文档", "写回正文", "应用到文档", "应用到正文",
            "应用这个结果", "应用刚才的结果", "替换正文", "替换原文",
            "保存到原文", "直接修改", "直接更新", "修改当前文档",
            "修改这篇文档", "修改该文档", "修改正文", "更新当前文档",
            "更新这篇文档", "更新正文"
        ]
        if let signal = explicitWriteSignals.first(where: { lower.contains($0) }) {
            return DocumentActionContract(
                output: .documentEditProposal,
                mutationPolicy: .proposeDocumentEdit,
                evidence: [signal]
            )
        }

        // “修改/删除 + 明确文档对象”属于写入；“整理/润色/优化”本身仍按只读处理。
        let writeVerbs = ["修改", "删除", "添加", "插入", "替换", "更新"]
        let writeTargets = ["当前文档", "这篇文档", "该文档", "正文", "原文"]
        if let verb = writeVerbs.first(where: { lower.contains($0) }),
           let target = writeTargets.first(where: { lower.contains($0) }) {
            return DocumentActionContract(
                output: .documentEditProposal,
                mutationPolicy: .proposeDocumentEdit,
                evidence: [verb, target]
            )
        }

        return DocumentActionContract(
            output: .conversation,
            mutationPolicy: .readOnly,
            evidence: []
        )
    }
}

/// 多维意图识别结果：任务目标、工具路由、输出位置和修改权限相互独立。
struct IntentClassification {
    let intent: UserIntent
    let goal: IntentGoal
    let confidence: Double
    let reason: String
    let preferredTools: [String]
    let output: IntentOutputDestination
    let mutationPolicy: IntentMutationPolicy
    let evidence: [String]

    var allowsDocumentProposal: Bool {
        mutationPolicy == .proposeDocumentEdit
    }

    init(
        intent: UserIntent,
        goal: IntentGoal = .converse,
        confidence: Double,
        reason: String,
        preferredTools: [String],
        actionContract: DocumentActionContract = .resolve("")
    ) {
        // editDocument 只有在用户给出明确写入信号时才成立。
        self.intent = intent == .editDocument && !actionContract.allowsDocumentProposal ? .chat : intent
        self.goal = goal
        self.confidence = confidence
        self.reason = reason
        self.output = actionContract.output
        self.mutationPolicy = actionContract.mutationPolicy
        self.evidence = actionContract.evidence
        self.preferredTools = actionContract.allowsDocumentProposal
            ? preferredTools
            : preferredTools.filter { $0 != "apply_markdown_edit" && $0 != "apply_text_edit" }
    }
}

/// 轻量级意图识别服务：高精度操作边界 + 规则启发 + LLM 语义分类
///
/// 设计原则：
/// 1. 先走低成本规则匹配，命中直接返回，避免每次请求都调用模型。
/// 2. 规则不确定时，再用 LLM 做 few-shot 结构化分类。
/// 3. 写入权限只来自用户原话中的明确证据；模糊表达默认只读。
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

        let actionContract = DocumentActionContract.resolve(trimmed)

        // 1. 低成本规则启发
        if let heuristic = heuristicClassify(
            trimmed,
            documentText: documentText,
            actionContract: actionContract
        ) {
            return heuristic
        }

        // 2. 规则不确定时，使用 LLM few-shot 分类
        return await llmClassify(
            text: trimmed,
            documentText: documentText,
            availableTools: availableTools,
            configuration: configuration,
            apiKey: apiKey,
            actionContract: actionContract
        )
    }

    // MARK: - 规则启发

    func heuristicClassify(
        _ text: String,
        documentText: String,
        actionContract: DocumentActionContract? = nil
    ) -> IntentClassification? {
        let lower = text.lowercased()
        let actionContract = actionContract ?? DocumentActionContract.resolve(text)

        // 记忆类意图通常非常明确
        if lower.contains("记住") || lower.contains("记下来") || lower.contains("以后记得") {
            return IntentClassification(intent: .recordMemory, goal: .recordMemory, confidence: 0.95, reason: "用户明确要求记录", preferredTools: UserIntent.recordMemory.preferredToolNames, actionContract: actionContract)
        }

        // 联网搜索
        let webKeywords = ["网上搜索", "搜一下", "google", "百度", "必应", "查一下网上", "联网", "web search"]
        if webKeywords.contains(where: { lower.contains($0) }) {
            return IntentClassification(intent: .webSearch, goal: .searchWeb, confidence: 0.9, reason: "包含联网搜索关键词", preferredTools: UserIntent.webSearch.preferredToolNames, actionContract: actionContract)
        }

        // 项目文档检索：包含“项目”+“搜索/检索/查找/查”
        let projectSearchPattern = ["项目", "文档", "文件"]
        let searchVerbs = ["搜索", "检索", "查找", "查", "找", "有没有", "哪些"]
        let hasProject = projectSearchPattern.contains(where: { lower.contains($0) })
        let hasSearchVerb = searchVerbs.contains(where: { lower.contains($0) })
        if hasProject && hasSearchVerb {
            return IntentClassification(intent: .queryProjectDocs, goal: .retrieve, confidence: 0.85, reason: "项目+搜索关键词", preferredTools: UserIntent.queryProjectDocs.preferredToolNames, actionContract: actionContract)
        }

        // 读取项目文件：包含“打开/读取/查看”+ 路径或扩展名
        let readVerbs = ["打开", "读取", "查看", "读一下", "看一下"]
        let hasReadVerb = readVerbs.contains(where: { lower.contains($0) })
        let hasPath = text.contains("/") || text.contains("\\") || text.contains(".")
        if hasReadVerb && hasPath {
            return IntentClassification(intent: .readProjectFile, goal: .retrieve, confidence: 0.85, reason: "读取+路径/文件名", preferredTools: UserIntent.readProjectFile.preferredToolNames, actionContract: actionContract)
        }

        // 引用文件到上下文
        let contextVerbs = ["加入上下文", "引用", "放到上下文", "一起分析"]
        if contextVerbs.contains(where: { lower.contains($0) }) && hasPath {
            return IntentClassification(intent: .addProjectFileToContext, goal: .retrieve, confidence: 0.85, reason: "引用文件到上下文", preferredTools: UserIntent.addProjectFileToContext.preferredToolNames, actionContract: actionContract)
        }

        let documentGoal = Self.documentGoal(for: lower)
        if actionContract.allowsDocumentProposal {
            let goal = documentGoal == .converse ? .rewrite : documentGoal
            return IntentClassification(
                intent: .editDocument,
                goal: goal,
                confidence: 0.95,
                reason: "用户明确要求将结果写回文档",
                preferredTools: UserIntent.editDocument.preferredToolNames,
                actionContract: actionContract
            )
        }

        // 总结、整理、润色和翻译描述的是内容目标，默认在对话中给出结果。
        if documentGoal != .converse {
            let hasDocumentContext = !documentText.isEmpty
                || ["文档", "文章", "当前", "这段", "全文", "markdown", "正文"]
                    .contains(where: { lower.contains($0) })
            return IntentClassification(
                intent: .chat,
                goal: documentGoal,
                confidence: hasDocumentContext ? 0.95 : 0.85,
                reason: actionContract.evidence.isEmpty
                    ? "识别到内容处理目标，但没有明确写回指令，默认在对话中输出"
                    : "用户明确要求只在对话中输出",
                preferredTools: [],
                actionContract: actionContract
            )
        }

        // 查询记忆/历史文件
        let memoryVerbs = ["我以前", "我之前", "我习惯", "我喜欢", "我最近", "我的偏好"]
        if memoryVerbs.contains(where: { lower.contains($0) }) {
            return IntentClassification(intent: .queryMemory, goal: .queryMemory, confidence: 0.75, reason: "涉及用户历史/偏好", preferredTools: UserIntent.queryMemory.preferredToolNames, actionContract: actionContract)
        }

        // 规则未命中，交给 LLM
        return nil
    }

    private static func documentGoal(for text: String) -> IntentGoal {
        if ["生成目录", "生成提纲", "列个提纲", "目录结构"].contains(where: { text.contains($0) }) {
            return .createOutline
        }
        if ["翻译", "中译英", "英译中"].contains(where: { text.contains($0) }) {
            return .translate
        }
        if ["总结", "简介", "概述", "摘要", "提炼", "核心观点", "主要内容"].contains(where: { text.contains($0) }) {
            return .summarize
        }
        if ["整理", "梳理", "理清", "结构化"].contains(where: { text.contains($0) }) {
            return .organize
        }
        if ["润色", "改写", "重写", "优化表达", "调整表述"].contains(where: { text.contains($0) }) {
            return .rewrite
        }
        if ["解释", "说明", "讲解", "什么意思"].contains(where: { text.contains($0) }) {
            return .explain
        }
        return .converse
    }

    // MARK: - LLM 分类

    private func llmClassify(
        text: String,
        documentText: String,
        availableTools: [ToolDefinition],
        configuration: AIProviderConfiguration,
        apiKey: String,
        actionContract: DocumentActionContract
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
            return parseClassification(
                content,
                fallbackReason: "LLM 分类",
                actionContract: actionContract
            )
        } catch {
            return IntentClassification(intent: .unknown, goal: .unknown, confidence: 0.0, reason: "分类失败: \(error.localizedDescription)", preferredTools: [], actionContract: actionContract)
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
          "goal": "retrieve",
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
        7. “总结、整理、梳理、润色、翻译、优化”只描述内容目标，默认 intent 为 "chat"，在对话中输出结果。
        8. 只有用户明确说“修改当前文档、替换正文、写回文档、应用到文档”等写入指令时，才使用 "edit_document"。
        9. 如果表达含糊，必须选择只读的 "chat"，不得猜测用户希望修改原文。
        10. 如果用户明确要求联网搜索，请使用 "web_search"。
        11. 如果用户询问自己的偏好、历史文件或工作习惯，请使用 "query_memory"。
        12. 如果用户要求记住某件事，请使用 "record_memory"。
        13. goal 必须是：\(IntentGoal.allCases.map(\.rawValue).joined(separator: ", "))。
        """
    }

    private func parseClassification(
        _ content: String,
        fallbackReason: String,
        actionContract: DocumentActionContract
    ) -> IntentClassification {
        // 尝试提取 JSON 块
        let jsonString: String
        if let start = content.range(of: "{"), let end = content.range(of: "}", range: start.upperBound..<content.endIndex) {
            jsonString = String(content[start.lowerBound..<end.upperBound])
        } else {
            jsonString = content
        }

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return IntentClassification(intent: .unknown, goal: .unknown, confidence: 0.0, reason: "无法解析分类结果", preferredTools: [], actionContract: actionContract)
        }

        let intentRaw = json["intent"] as? String ?? "unknown"
        let confidence = (json["confidence"] as? Double) ?? 0.0
        let reason = (json["reason"] as? String) ?? fallbackReason
        let goalRaw = json["goal"] as? String ?? IntentGoal.converse.rawValue

        let intent = UserIntent(rawValue: intentRaw) ?? .unknown
        let goal = IntentGoal(rawValue: goalRaw) ?? .unknown
        return IntentClassification(
            intent: intent,
            goal: goal,
            confidence: confidence,
            reason: intent == .editDocument && !actionContract.allowsDocumentProposal
                ? "\(reason)；未发现明确写回指令，已降级为只读输出"
                : reason,
            preferredTools: intent.preferredToolNames,
            actionContract: actionContract
        )
    }
}
