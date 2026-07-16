import Foundation

extension String {
    /// 生成与预览模板一致的锚点 ID：保留中英文/数字，移除标点和空白，多个分隔符合并为 "-"。
    func markdownHeadingSlug() -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "\u{4e00}"..."\u{9fff}"))
        var result = self
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .components(separatedBy: allowed.inverted)
            .joined(separator: "-")
        // 合并连续的 "-"
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
