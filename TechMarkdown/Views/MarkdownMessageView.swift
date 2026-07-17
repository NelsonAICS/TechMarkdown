import SwiftUI
import AppKit

struct MarkdownMessageView: View {
    let content: String
    @Bindable var themeManager: ThemeManager

    private var blocks: [MarkdownMessageBlock] {
        MarkdownMessageParser.parse(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownMessageBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .foregroundStyle(themeManager.textPrimary)
                .padding(.top, level <= 2 ? 4 : 1)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.system(size: 13))
                .lineSpacing(5)
                .foregroundStyle(themeManager.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

        case .unorderedList(let items), .orderedList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(themeManager.accentSecondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(inlineMarkdown(item.content))
                            .font(.system(size: 13))
                            .lineSpacing(4)
                            .foregroundStyle(themeManager.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(themeManager.accentSecondary)
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .font(.system(size: 12))
                    .lineSpacing(4)
                    .foregroundStyle(themeManager.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(themeManager.textMuted)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(themeManager.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.backgroundCode)
            )

        case .table(let rows):
            MarkdownMessageTable(rows: rows, themeManager: themeManager)

        case .divider:
            Divider().overlay(themeManager.border)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 18, weight: .bold)
        case 2: return .system(size: 16, weight: .bold)
        case 3: return .system(size: 14, weight: .semibold)
        default: return .system(size: 13, weight: .semibold)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// 聊天侧栏中的表格优先完整占满消息宽度。每个单元格都是可伸缩列，
/// 因此表头和正文底色不会只停留在文字的固有宽度上。
private struct MarkdownMessageTable: View {
    let rows: [[String]]
    @Bindable var themeManager: ThemeManager
    @State private var selectedCell: MarkdownTableCellDetail?

    private var columnCount: Int {
        max(1, rows.map(\.count).max() ?? 1)
    }

    private var hasExpandableCells: Bool {
        rows.dropFirst().flatMap { $0 }.contains(where: isLikelyTruncated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 1, verticalSpacing: 1) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { columnIndex in
                            let cell = columnIndex < row.count ? row[columnIndex] : ""
                            tableCell(cell, rowIndex: rowIndex, columnIndex: columnIndex)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(themeManager.tableGrid)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(themeManager.tableGrid, lineWidth: 1)
            }

            if hasExpandableCells {
                Label("点击单元格查看完整内容", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(themeManager.textMuted)
                    .padding(.leading, 2)
            }
        }
        .sheet(item: $selectedCell) { detail in
            MarkdownTableCellDetailView(detail: detail, themeManager: themeManager)
                .environment(themeManager)
        }
    }

    private func tableCell(_ cell: String, rowIndex: Int, columnIndex: Int) -> some View {
        let expandable = rowIndex > 0 && !cell.isEmpty
        let likelyTruncated = isLikelyTruncated(cell)

        return Text(inlineMarkdown(cell))
            .font(.system(size: rowIndex == 0 ? 11.5 : 11, weight: rowIndex == 0 ? .bold : .regular))
            .foregroundStyle(cellForeground(rowIndex: rowIndex))
            .lineSpacing(2)
            .lineLimit(2)
            .truncationMode(.tail)
            .padding(.leading, 9)
            .padding(.trailing, likelyTruncated && rowIndex > 0 ? 19 : 9)
            .padding(.vertical, rowIndex == 0 ? 9 : 7)
            .frame(minWidth: 64, maxWidth: .infinity, minHeight: rowIndex == 0 ? 38 : 34, alignment: .topLeading)
            .background(cellBackground(rowIndex: rowIndex))
            .overlay(alignment: .bottom) {
                if rowIndex == 0 {
                    Rectangle()
                        .fill(themeManager.accentSecondary.opacity(themeManager.theme == .dark ? 0.9 : 0.75))
                        .frame(height: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if rowIndex > 0 && likelyTruncated {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(themeManager.accentSecondary)
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard expandable else { return }
                selectedCell = MarkdownTableCellDetail(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnTitle: columnTitle(at: columnIndex),
                    rowTitle: rowTitle(at: rowIndex),
                    content: cell
                )
            }
            .help(expandable ? "点击查看完整内容" : "")
    }

    private func cellBackground(rowIndex: Int) -> Color {
        if rowIndex == 0 {
            return themeManager.tableHeaderBackground
        }
        return rowIndex.isMultiple(of: 2)
            ? themeManager.tableAlternateRowBackground
            : themeManager.tableRowBackground
    }

    private func cellForeground(rowIndex: Int) -> Color {
        guard rowIndex == 0 else { return themeManager.textPrimary }
        return themeManager.tableHeaderForeground
    }

    private func isLikelyTruncated(_ text: String) -> Bool {
        text.count > 12 || text.contains("\n")
    }

    private func columnTitle(at index: Int) -> String {
        guard let header = rows.first, index < header.count, !header[index].isEmpty else {
            return "第 \(index + 1) 列"
        }
        return header[index]
    }

    private func rowTitle(at index: Int) -> String {
        guard index < rows.count, let title = rows[index].first, !title.isEmpty else {
            return "第 \(index) 行"
        }
        return title
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct MarkdownTableCellDetail: Identifiable {
    let rowIndex: Int
    let columnIndex: Int
    let columnTitle: String
    let rowTitle: String
    let content: String

    var id: String { "\(rowIndex)-\(columnIndex)" }
}

struct MarkdownTableCellDetailView: View {
    let detail: MarkdownTableCellDetail
    @Bindable var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.columnTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(themeManager.textPrimary)
                    Text(detail.rowTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(themeManager.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail.content, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(themeManager.textPrimary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(themeManager.backgroundTertiary)
                        )
                }
                .buttonStyle(.plain)

                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(themeManager.backgroundSecondary)

            Divider().overlay(themeManager.border)

            ScrollView(.vertical) {
                Text(inlineMarkdown(detail.content))
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundStyle(themeManager.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }
            .background(themeManager.backgroundPrimary)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 300, idealHeight: 460)
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
