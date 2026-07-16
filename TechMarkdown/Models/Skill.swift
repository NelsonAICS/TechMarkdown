import Foundation

struct SkillDefinition: Identifiable, Hashable {
    let id: String
    var name: String
    var description: String
    var icon: String
    var promptTemplate: String
    var suggestedTools: [String]
}

enum BuiltInSkill {
    static let summarize = SkillDefinition(
        id: "summarize",
        name: "总结文档",
        description: "提炼当前 Markdown 文档的核心观点与结构",
        icon: "text.alignleft",
        promptTemplate: "请直接对以下 Markdown 文档进行完整总结，列出核心观点、主要结构和关键结论。不要只回复“查看”或进行简短确认，必须输出实质性的总结内容。",
        suggestedTools: []
    )
    
    static let polish = SkillDefinition(
        id: "polish",
        name: "润色优化",
        description: "改进文档表达、语法和可读性",
        icon: "sparkles",
        promptTemplate: "请润色以下 Markdown 文档，使其表达更流畅、专业，同时保持原意和结构。",
        suggestedTools: ["apply_markdown_edit"]
    )
    
    static let translate = SkillDefinition(
        id: "translate",
        name: "中英互译",
        description: "将文档翻译成指定语言",
        icon: "globe",
        promptTemplate: "请将以下 Markdown 文档翻译成 {{target}}，保持原有格式和 Markdown 语法。",
        suggestedTools: ["apply_markdown_edit"]
    )
    
    static let explain = SkillDefinition(
        id: "explain",
        name: "解释说明",
        description: "解释文档中的概念、公式或代码",
        icon: "questionmark.circle",
        promptTemplate: "请解释以下 Markdown 文档中的关键概念、公式或代码片段，帮助读者深入理解。",
        suggestedTools: []
    )
    
    static let generateTOC = SkillDefinition(
        id: "generate_toc",
        name: "生成目录",
        description: "根据标题自动生成目录",
        icon: "list.number",
        promptTemplate: "请根据以下 Markdown 文档的标题结构生成一个目录（Table of Contents），使用 Markdown 链接格式。",
        suggestedTools: ["apply_markdown_edit"]
    )
    
    static let documentRetrieval = SkillDefinition(
        id: "document_retrieval",
        name: "项目文档检索",
        description: "浏览项目文件、读取项目内文档或进行项目级检索",
        icon: "folder.badge.gear",
        promptTemplate: "请基于当前项目目录，帮助用户浏览项目文件、读取相关文档，或根据用户问题进行项目级文档检索。必要时调用 list_project_files / read_project_file / add_project_file_to_context / query_project_documents 工具。",
        suggestedTools: [
            "list_project_files",
            "read_project_file",
            "add_project_file_to_context",
            "query_project_documents"
        ]
    )
    
    static let formatLaTeX = SkillDefinition(
        id: "format_latex",
        name: "格式化 LaTeX",
        description: "整理 LaTeX 文档格式、对齐环境与命令",
        icon: "textformat",
        promptTemplate: "请整理以下 LaTeX 文档的格式：保持缩进一致、环境对齐、命令规范，确保文档结构清晰且可编译。",
        suggestedTools: ["apply_text_edit"]
    )
    
    static let checkLaTeX = SkillDefinition(
        id: "check_latex",
        name: "检查 LaTeX",
        description: "检查 LaTeX 语法与常见编译问题",
        icon: "checkmark.shield",
        promptTemplate: "请检查以下 LaTeX 文档中的语法错误、缺失环境、未闭合括号、重复宏包等常见编译问题，并给出修复建议。",
        suggestedTools: ["apply_text_edit"]
    )
    
    static let all: [SkillDefinition] = [summarize, polish, translate, explain, generateTOC, documentRetrieval, formatLaTeX, checkLaTeX]
}
