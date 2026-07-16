import SwiftUI

private struct HeadingItem: Identifiable {
    let id: String
    let line: Int
    let level: Int
    let title: String

    var slug: String { title.markdownHeadingSlug() }
}

/// 悬浮 Markdown 目录面板
struct TableOfContentsView: View {
    @EnvironmentObject var documentState: DocumentState
    let themeManager: ThemeManager

    @State private var isExpanded = false
    @State private var hoveredID: String?
    @State private var headings: [HeadingItem] = []

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 透明背景只用于布局，不拦截下方 WKWebView 的滚动/点击
            Color.clear
                .allowsHitTesting(false)

            if !headings.isEmpty {
                tocButtonOrPanel
                    .padding(12)
            }
        }
        .task(id: documentState.text) {
            // 防抖：输入停止 300ms 后再提取目录，避免每次按键都触发正则扫描
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            refreshHeadings()
        }
    }

    private var tocButtonOrPanel: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("目录")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(themeManager.textPrimary)

                        Spacer()

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isExpanded = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(themeManager.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(headings) { heading in
                                Button {
                                    NotificationCenter.default.post(
                                        name: .scrollPreviewToHeading,
                                        object: heading.slug
                                    )
                                } label: {
                                    Text(heading.title)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                        .foregroundColor(themeManager.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(hoveredID == heading.id
                                                      ? Color.accentColor.opacity(0.15)
                                                      : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 4)
                                .padding(.leading, CGFloat(heading.level - 1) * 10)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    hoveredID = hovering ? heading.id : nil
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 320)
                }
                .frame(width: 220)
                .background(themeManager.backgroundSecondary)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(themeManager.border, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded = true
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(themeManager.textPrimary)
                        .frame(width: 30, height: 30)
                        .background(themeManager.backgroundSecondary)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(themeManager.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("显示目录")
            }
        }
    }

    @MainActor
    private func refreshHeadings() {
        headings = Self.extractHeadings(from: documentState.text)
    }

    private static func extractHeadings(from text: String) -> [HeadingItem] {
        var items: [HeadingItem] = []
        let pattern = "^(#{1,6})\\s+(.+?)(?:\\s+#*)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return items
        }
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: text.utf16.count)
        )
        for match in matches {
            guard let levelRange = Range(match.range(at: 1), in: text),
                  let titleRange = Range(match.range(at: 2), in: text) else { continue }
            let level = text[levelRange].count
            let title = String(text[titleRange]).trimmingCharacters(in: .whitespaces)
            let line = text[..<titleRange.lowerBound].components(separatedBy: .newlines).count
            let slug = title.markdownHeadingSlug()
            items.append(HeadingItem(
                id: "\(line)-\(slug)",
                line: line,
                level: level,
                title: title
            ))
        }
        return items
    }
}
