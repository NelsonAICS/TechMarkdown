import SwiftUI

struct DiffView: View {
    let oldText: String
    let newText: String
    @Bindable var themeManager: ThemeManager
    
    var body: some View {
        let diff = computeLineDiff(oldText: oldText, newText: newText)
        
        HSplitView {
            DiffColumnView(
                title: "当前文档",
                lines: diff.filter { $0.type != .added },
                themeManager: themeManager,
                isLeft: true
            )
            DiffColumnView(
                title: "对比文档",
                lines: diff.filter { $0.type != .removed },
                themeManager: themeManager,
                isLeft: false
            )
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

struct DiffColumnView: View {
    let title: String
    let lines: [DiffLine]
    @Bindable var themeManager: ThemeManager
    let isLeft: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(themeManager.backgroundTertiary)
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: 0) {
                            Text("\(line.oldLineNumber ?? line.newLineNumber ?? 0)")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 40, alignment: .trailing)
                                .padding(.trailing, 8)
                                .foregroundColor(themeManager.textMuted)
                            
                            Text(line.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(textColor(for: line.type))
                                .padding(.vertical, 1)
                            
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(backgroundColor(for: line.type))
                    }
                }
            }
        }
    }
    
    private func textColor(for type: DiffLineType) -> Color {
        switch type {
        case .unchanged:
            return themeManager.textPrimary
        case .added:
            return themeManager.success
        case .removed:
            return themeManager.error
        }
    }
    
    private func backgroundColor(for type: DiffLineType) -> Color {
        switch type {
        case .unchanged:
            return Color.clear
        case .added:
            return themeManager.success.opacity(0.12)
        case .removed:
            return themeManager.error.opacity(0.12)
        }
    }
}
