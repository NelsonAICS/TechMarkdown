import Foundation

struct MarkdownListItem: Equatable {
    let marker: String
    let content: String
}

enum MarkdownMessageBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([MarkdownListItem])
    case orderedList([MarkdownListItem])
    case quote(String)
    case code(language: String?, content: String)
    case table([[String]])
    case divider
}

enum MarkdownMessageParser {
    static func parse(_ source: String) -> [MarkdownMessageBlock] {
        let normalized = normalize(source)
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownMessageBlock] = []
        var paragraphLines: [String] = []
        var unorderedItems: [MarkdownListItem] = []
        var orderedItems: [MarkdownListItem] = []
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var isInCodeBlock = false
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll()
        }

        func flushLists() {
            if !unorderedItems.isEmpty {
                blocks.append(.unorderedList(unorderedItems))
                unorderedItems.removeAll()
            }
            if !orderedItems.isEmpty {
                blocks.append(.orderedList(orderedItems))
                orderedItems.removeAll()
            }
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines.removeAll()
        }

        func flushTextBlocks() {
            flushParagraph()
            flushLists()
            flushQuote()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isInCodeBlock {
                if trimmed.hasPrefix("```") {
                    blocks.append(
                        .code(
                            language: codeLanguage?.isEmpty == true ? nil : codeLanguage,
                            content: codeLines.joined(separator: "\n")
                        )
                    )
                    codeLines.removeAll()
                    codeLanguage = nil
                    isInCodeBlock = false
                } else {
                    codeLines.append(line)
                }
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushTextBlocks()
                codeLanguage = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                isInCodeBlock = true
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushTextBlocks()
                index += 1
                continue
            }

            if
                line.contains("|"),
                index + 1 < lines.count,
                isTableSeparator(lines[index + 1])
            {
                flushTextBlocks()
                var rows = [tableCells(line)]
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            }

            if let heading = heading(from: trimmed) {
                flushTextBlocks()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if trimmed.range(of: #"^([-*_])\1{2,}$"#, options: .regularExpression) != nil {
                flushTextBlocks()
                blocks.append(.divider)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushLists()
                quoteLines.append(
                    String(trimmed.dropFirst())
                        .trimmingCharacters(in: .whitespaces)
                )
                index += 1
                continue
            }

            if let item = unorderedItem(from: trimmed) {
                flushParagraph()
                flushQuote()
                if !orderedItems.isEmpty { flushLists() }
                unorderedItems.append(item)
                index += 1
                continue
            }

            if let item = orderedItem(from: trimmed) {
                flushParagraph()
                flushQuote()
                if !unorderedItems.isEmpty { flushLists() }
                orderedItems.append(item)
                index += 1
                continue
            }

            flushLists()
            flushQuote()
            paragraphLines.append(trimmed)
            index += 1
        }

        if isInCodeBlock {
            blocks.append(.code(language: codeLanguage, content: codeLines.joined(separator: "\n")))
        }
        flushTextBlocks()
        return blocks
    }

    static func normalize(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(
            of: #"([^#\n])(?=(#{1,6}\s+))"#,
            with: "$1\n\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"([^\n])\s*[—-]{2,}\s*([一二三四五六七八九十]+、)"#,
            with: "$1\n\n## $2",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"([^\n])(?=(?:📌|🚀|📚|🎯|💡|✅|⚠️)\s*)"#,
            with: "$1\n\n",
            options: .regularExpression
        )
        return text
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        guard let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else {
            return nil
        }
        let marker = line[range]
        let level = marker.filter { $0 == "#" }.count
        let text = String(line[range.upperBound...])
        return (level, text)
    }

    private static func unorderedItem(from line: String) -> MarkdownListItem? {
        guard let range = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) else {
            return nil
        }
        return MarkdownListItem(marker: "•", content: String(line[range.upperBound...]))
    }

    private static func orderedItem(from line: String) -> MarkdownListItem? {
        guard let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) else {
            return nil
        }
        let marker = String(line[range]).trimmingCharacters(in: .whitespaces)
        return MarkdownListItem(marker: marker, content: String(line[range.upperBound...]))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy {
            $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
