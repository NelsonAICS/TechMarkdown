import Foundation

final class MarkdownEditService {
    static let shared = MarkdownEditService()
    private init() {}
    
    /// 从 AI 回复中提取 apply_markdown_edit 工具参数或直接输出的完整 Markdown
    func extractSuggestedEdit(from response: String, originalText: String) -> (suggestedText: String, reason: String)? {
        // 优先查找 ```markdown 代码块
        let codeBlockPattern = #"```markdown\n([\s\S]*?)\n```"#
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern, options: []),
           let match = regex.firstMatch(in: response, options: [], range: NSRange(location: 0, length: response.utf16.count)),
           let range = Range(match.range(at: 1), in: response) {
            let suggested = String(response[range])
            return (suggested, "AI 建议的 Markdown 修改")
        }
        
        // 其次查找 ``` 代码块
        let genericBlockPattern = #"```\n([\s\S]*?)\n```"#
        if let regex = try? NSRegularExpression(pattern: genericBlockPattern, options: []),
           let match = regex.firstMatch(in: response, options: [], range: NSRange(location: 0, length: response.utf16.count)),
           let range = Range(match.range(at: 1), in: response) {
            let suggested = String(response[range])
            if suggested.hasPrefix("#") || suggested.contains("**") || suggested.contains("[") {
                return (suggested, "AI 建议的 Markdown 修改")
            }
        }
        
        return nil
    }
    
    func applyEdit(suggestedText: String, to document: inout MarkdownDocument) {
        document.text = suggestedText
    }
}
