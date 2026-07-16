import SwiftUI

struct TabBarView: View {
    let tabs: [DocumentTab]
    let selectedID: UUID?
    let themeManager: ThemeManager
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onPin: (UUID) -> Void
    let onCloseOthers: (UUID) -> Void
    let onCloseAll: () -> Void
    let onCloseToRight: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(height: 36)
        .background(themeManager.backgroundSecondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(themeManager.border),
            alignment: .bottom
        )
    }

    private func tabButton(_ tab: DocumentTab) -> some View {
        let selected = selectedID == tab.id
        return Button {
            onSelect(tab.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconFor(tab))
                    .font(.system(size: 12))
                    .foregroundColor(selected ? themeManager.textPrimary : themeManager.textSecondary)

                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundColor(themeManager.accent)
                        .rotationEffect(.degrees(45))
                }

                Text(tab.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? themeManager.textPrimary : themeManager.textSecondary)
                    .lineLimit(1)

                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 12, height: 12)
                }

                if !tab.isDocument && !tab.isPinned {
                    Button {
                        onClose(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(themeManager.textMuted)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? themeManager.backgroundPrimary : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? themeManager.border : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            tabContextMenu(for: tab)
        }
    }

    @ViewBuilder
    private func tabContextMenu(for tab: DocumentTab) -> some View {
        if !tab.isDocument {
            Button {
                onPin(tab.id)
            } label: {
                Label(tab.isPinned ? "取消固定" : "固定", systemImage: tab.isPinned ? "pin.slash" : "pin")
            }

            Divider()
        }

        if !tab.isDocument {
            Button {
                onClose(tab.id)
            } label: {
                Label("关闭", systemImage: "xmark")
            }
        }

        Button {
            onCloseOthers(tab.id)
        } label: {
            Label("关闭其他", systemImage: "arrow.left.arrow.right")
        }

        Button {
            onCloseToRight(tab.id)
        } label: {
            Label("关闭右侧标签页", systemImage: "arrow.right")
        }

        Button {
            onCloseAll()
        } label: {
            Label("关闭所有", systemImage: "xmark.rectangle")
        }
    }

    private func iconFor(_ tab: DocumentTab) -> String {
        switch tab.format {
        case .html: return "safari"
        case .latex: return "doc.text"
        case .markdown: return "doc.plaintext"
        }
    }
}
