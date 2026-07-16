import Foundation

enum AIProviderID: String, Codable, CaseIterable, Identifiable {
    case openAI
    case gemini
    case doubao
    case arkCoding
    case qwen
    case deepseek
    case tokenAPIGate
    case custom
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .doubao: return "豆包 / 火山方舟"
        case .arkCoding: return "火山方舟 Coding Plan"
        case .qwen: return "通义千问"
        case .deepseek: return "DeepSeek"
        case .tokenAPIGate: return "TokenAPIGate（本地网关）"
        case .custom: return "自定义 OpenAI 兼容"
        }
    }
    
    var preset: AIProviderPreset {
        switch self {
        case .openAI:
            return AIProviderPreset(
                id: self,
                title: "OpenAI",
                apiKeyName: "OPENAI_API_KEY",
                chatCompletionsURL: "https://api.openai.com/v1/chat/completions",
                models: ["gpt-4o-mini", "gpt-4o", "gpt-5.4-mini", "gpt-5.4"],
                defaultModel: "gpt-4o-mini"
            )
        case .gemini:
            return AIProviderPreset(
                id: self,
                title: "Google Gemini",
                apiKeyName: "GEMINI_API_KEY",
                chatCompletionsURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                models: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-3-flash-preview"],
                defaultModel: "gemini-2.5-flash"
            )
        case .doubao:
            return AIProviderPreset(
                id: self,
                title: "豆包 / 火山方舟",
                apiKeyName: "ARK_API_KEY",
                chatCompletionsURL: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
                models: ["doubao-seed-1-6-251015", "doubao-seed-1-6-250615"],
                defaultModel: "doubao-seed-1-6-251015"
            )
        case .arkCoding:
            return AIProviderPreset(
                id: self,
                title: "火山方舟 Coding Plan",
                apiKeyName: "ARK_API_KEY",
                chatCompletionsURL: "https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions",
                models: [
                    "ark-code-latest",
                    "doubao-seed-2.0-code",
                    "doubao-seed-2.0-pro",
                    "doubao-seed-2.0-lite",
                    "doubao-seed-code",
                    "minimax-m2.7",
                    "minimax-m3",
                    "glm-5.2",
                    "deepseek-v4-flash",
                    "deepseek-v4-pro",
                    "kimi-k2.6",
                    "kimi-k2.7-code"
                ],
                defaultModel: "ark-code-latest"
            )
        case .qwen:
            return AIProviderPreset(
                id: self,
                title: "通义千问",
                apiKeyName: "DASHSCOPE_API_KEY",
                chatCompletionsURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                models: ["qwen-plus-latest", "qwen-turbo-latest", "qwen3-vl-plus"],
                defaultModel: "qwen-plus-latest"
            )
        case .deepseek:
            return AIProviderPreset(
                id: self,
                title: "DeepSeek",
                apiKeyName: "DEEPSEEK_API_KEY",
                chatCompletionsURL: "https://api.deepseek.com/chat/completions",
                models: ["deepseek-v4-flash", "deepseek-v4-pro"],
                defaultModel: "deepseek-v4-flash"
            )
        case .tokenAPIGate:
            return AIProviderPreset(
                id: self,
                title: "TokenAPIGate",
                apiKeyName: "TOKENAPIGATE_KEY",
                chatCompletionsURL: "http://127.0.0.1:8686/v1/chat/completions",
                models: [],
                defaultModel: ""
            )
        case .custom:
            return AIProviderPreset(
                id: self,
                title: "自定义 OpenAI 兼容",
                apiKeyName: "API_KEY",
                chatCompletionsURL: "https://api.openai.com/v1/chat/completions",
                models: [],
                defaultModel: ""
            )
        }
    }
}

struct AIProviderPreset: Hashable {
    let id: AIProviderID
    let title: String
    let apiKeyName: String
    let chatCompletionsURL: String
    let models: [String]
    let defaultModel: String
}

struct AIProviderConfiguration: Codable, Hashable {
    var providerID: AIProviderID = .openAI
    var baseURL: String = AIProviderID.openAI.preset.chatCompletionsURL
    var model: String = AIProviderID.openAI.preset.defaultModel
    var apiKeyAccount: String = "default"
    var temperature: Double = 0.3
    var maxHistoryTurns: Int = 10
    var systemPrompt: String = "你是一个专业的 Markdown / LaTeX 编辑助手。请严格遵循以下规则：\n1. 当前文档内容已经通过系统消息提供，你可以直接分析，无需调用 read_file 来读取当前文档。\n2. 如果用户要求总结、润色、翻译或生成目录等，请直接给出完整、结构化的回答，不要只回复“查看”“好的”等简短确认。\n3. 当任务需要搜索当前文档、读取本地其他文件、查询互联网或修改文档时，请主动调用对应工具；一次工具结果不够时，请继续多步思考并调用工具，直到给出最终答案。\n4. 当用户要求写入、修改或更新当前文档时：\n   - 如果当前是 Markdown 文档，必须调用 apply_markdown_edit 工具，将修改后的完整 Markdown 文本作为 markdown 参数传入。\n   - 如果当前是 LaTeX 文档（.tex），必须调用 apply_text_edit 工具，将修改后的完整 LaTeX 文本作为 text 参数传入。\n   - 如果当前是 HTML 文档（.html/.htm），必须调用 apply_text_edit 工具，将修改后的完整 HTML 文本作为 text 参数传入。\n   无论哪种情况，都要简要说明修改原因。禁止在回复正文中直接输出修改后的全文、工具调用语法、<| | DSML | |> 标记或类似标记。调用工具后不输出原文，只需简要告知用户已生成修改建议，请其在侧边栏确认。\n5. 如需联网搜索，先调用 web_search 获取结果；如需查看某网页详情，再调用 web_read 读取正文。搜索和阅读结果只在工具内部使用，不要整段输出到聊天里。\n6. 调用 apply_markdown_edit 或 apply_text_edit 后，修改建议会显示在侧边栏的“待确认修改”面板中，用户确认后才会真正写入文档。\n7. 调用工具后必须根据工具返回结果直接回答用户，不要重复要求用户自己查看。\n8. 保持回答简洁、专业，优先使用中文。\n9. 当用户询问历史文件、项目或自身偏好/习惯时，优先调用 query_user_memory 或 search_file_index 工具；当用户明确要求记住某件事时，调用 record_memory 工具。\n10. 当用户需要浏览项目文件、读取项目内其他文档或进行项目级检索时，调用 list_project_files / read_project_file / add_project_file_to_context / query_project_documents 工具。\n11. 当用户处理 LaTeX 文档时，注意保持 LaTeX 语法和结构完整；如需检查编译错误，可建议用户点击“编译并下载 PDF”按钮进行验证。"
    
    enum CodingKeys: String, CodingKey {
        case providerID, baseURL, model, apiKeyAccount, temperature, maxHistoryTurns
    }
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(AIProviderID.self, forKey: .providerID) ?? .openAI
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? providerID.preset.chatCompletionsURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? providerID.preset.defaultModel
        apiKeyAccount = try container.decodeIfPresent(String.self, forKey: .apiKeyAccount) ?? "default"
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.3
        maxHistoryTurns = try container.decodeIfPresent(Int.self, forKey: .maxHistoryTurns) ?? 10
    }
}
