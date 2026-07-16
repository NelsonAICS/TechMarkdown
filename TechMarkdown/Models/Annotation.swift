import Foundation

enum AnnotationSource: String, Codable, Equatable, Sendable {
    case editor
    case preview
    case document
}

/// 用户从编辑器或预览区发起批注时传给侧栏编辑器的草稿。
struct AnnotationDraft: Equatable, Sendable {
    var text: String = ""
    let selectedText: String
    let context: String
    let rangeSnapshot: AnnotationRangeSnapshot?
    let source: AnnotationSource

    var isAnchored: Bool {
        !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 创建批注时选区在原文中的位置快照。
/// 用于文档修改后仍能稳定跳转回对应位置；可能缺失（例如从预览区创建时无法精确映射源码）。
struct AnnotationRangeSnapshot: Codable, Equatable, Sendable {
    /// 1-based 起始行号
    let startLine: Int
    /// 1-based 起始列号（行内 UTF-16 偏移）
    let startColumn: Int
    /// 1-based 结束行号
    let endLine: Int
    /// 1-based 结束列号（行内 UTF-16 偏移）
    let endColumn: Int

    init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
        self.startLine = max(1, startLine)
        self.startColumn = max(1, startColumn)
        self.endLine = max(1, endLine)
        self.endColumn = max(1, endColumn)
    }
}

enum AnnotationMatchQuality: Int, Comparable {
    case approximate = 1
    case relocated = 2
    case exact = 3

    static func < (lhs: AnnotationMatchQuality, rhs: AnnotationMatchQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct AnnotationMatch: Equatable {
    let range: NSRange
    let quality: AnnotationMatchQuality
}

/// 用户对文档添加的批注/备注，支持锚定到选中的文本片段。
/// AI 会在优化内容时自动读取未解决的批注作为上下文。
struct Annotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// 用户批注内容
    var text: String
    /// 被锚定的选中文本片段
    var selectedText: String
    /// 选中片段所在的上下文（例如所在行或段落），用于帮助定位
    var context: String
    /// 创建时选区在原文中的位置快照
    var rangeSnapshot: AnnotationRangeSnapshot?
    var createdAt: Date
    var updatedAt: Date
    var resolved: Bool

    init(
        id: UUID = UUID(),
        text: String,
        selectedText: String = "",
        context: String = "",
        rangeSnapshot: AnnotationRangeSnapshot? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        resolved: Bool = false
    ) {
        self.id = id
        self.text = text
        self.selectedText = selectedText
        self.context = context
        self.rangeSnapshot = rangeSnapshot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolved = resolved
    }

    /// 用于去重与分组的“位置签名”：选中内容 + 上下文。
    var locationSignature: String {
        let s = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(s)|\(c)"
    }
}

/// 编辑器与批注列表共用的锚点定位器。
///
/// 所有范围都使用 NSString 的 UTF-16 下标，与 NSTextView/NSRange 保持一致。
enum AnnotationLocator {
    static func locate(_ annotation: Annotation, in text: String) -> AnnotationMatch? {
        let nsText = text as NSString
        let rawSelected = annotation.selectedText
        let selected = rawSelected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, nsText.length > 0 else { return nil }

        if let snapshot = annotation.rangeSnapshot,
           let snapshotRange = range(from: snapshot, in: nsText) {
            let snapshotText = nsText.substring(with: snapshotRange)
            if snapshotText == rawSelected || snapshotText == selected {
                return AnnotationMatch(range: snapshotRange, quality: .exact)
            }

            if let nearby = nearestOccurrence(
                of: selected,
                in: nsText,
                to: snapshotRange.location
            ) {
                return AnnotationMatch(range: nearby, quality: .relocated)
            }
        }

        let normalizedContext = annotation.context
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedContext.isEmpty {
            let contextRange = nsText.range(of: normalizedContext)
            if contextRange.location != NSNotFound {
                let selectedRange = nsText.range(
                    of: selected,
                    options: [],
                    range: contextRange
                )
                if selectedRange.location != NSNotFound {
                    return AnnotationMatch(range: selectedRange, quality: .approximate)
                }
            }
        }

        let directRange = nsText.range(of: rawSelected)
        if directRange.location != NSNotFound {
            return AnnotationMatch(range: directRange, quality: .approximate)
        }

        let trimmedRange = nsText.range(of: selected)
        if trimmedRange.location != NSNotFound {
            return AnnotationMatch(range: trimmedRange, quality: .approximate)
        }

        return nil
    }

    static func range(from snapshot: AnnotationRangeSnapshot, in text: NSString) -> NSRange? {
        guard
            let startLineRange = lineRange(forLine: snapshot.startLine, in: text),
            let endLineRange = lineRange(forLine: snapshot.endLine, in: text)
        else {
            return nil
        }

        let start = startLineRange.location + snapshot.startColumn - 1
        let end = endLineRange.location + snapshot.endColumn
        guard
            start >= startLineRange.location,
            start <= NSMaxRange(startLineRange),
            end >= start,
            end <= NSMaxRange(endLineRange),
            end <= text.length
        else {
            return nil
        }

        return NSRange(location: start, length: end - start)
    }

    static func lineRange(forLine lineNumber: Int, in text: NSString) -> NSRange? {
        guard lineNumber >= 1 else { return nil }

        var currentLine = 1
        var location = 0
        while location <= text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            if currentLine == lineNumber {
                return range
            }
            currentLine += 1
            location = NSMaxRange(range)
            if range.length == 0 { break }
        }
        return nil
    }

    private static func nearestOccurrence(
        of query: String,
        in text: NSString,
        to expectedLocation: Int
    ) -> NSRange? {
        guard !query.isEmpty else { return nil }

        var searchLocation = 0
        var bestRange: NSRange?
        var bestDistance = Int.max

        while searchLocation < text.length {
            let searchRange = NSRange(
                location: searchLocation,
                length: text.length - searchLocation
            )
            let match = text.range(of: query, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }

            let distance = abs(match.location - expectedLocation)
            if distance < bestDistance {
                bestRange = match
                bestDistance = distance
            }

            searchLocation = max(NSMaxRange(match), match.location + 1)
        }

        return bestRange
    }
}
