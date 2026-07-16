import SwiftUI

/// 只读文件预览视图
///
/// 设计目的：从项目浏览器点击文件后，在主窗口以只读方式查看内容，
/// 不修改当前 `MarkdownDocument`，因此不会产生“未保存”提示或版本存储权限问题。
struct FilePreviewView: View {
    let file: ProjectFile
    let content: String
    let themeManager: ThemeManager
    let onClose: () -> Void
    let onOpenInNewWindow: () -> Void

    @StateObject private var previewState = DocumentState()

    var body: some View {
        VStack(spacing: 0) {
            previewTopBar

            ZStack {
                PreviewView(themeManager: themeManager)
                TableOfContentsView(themeManager: themeManager)
            }
            .environmentObject(previewState)

            previewStatusBar
        }
        .onAppear(perform: syncPreviewState)
        .onChange(of: content, syncPreviewState)
        .onChange(of: file, syncPreviewState)
    }

    private func syncPreviewState() {
        previewState.text = content
        previewState.currentFileURL = file.url
        previewState.format = DocumentFormat.forURL(file.url) ?? .markdown
    }

    private var previewTopBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                    Text("关闭预览")
                }
                .font(.system(size: 12))
                .foregroundColor(themeManager.textSecondary)
            }
            .buttonStyle(.plain)
            .help("返回当前文档")

            Spacer()

            VStack(spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(themeManager.textPrimary)
                    .lineLimit(1)

                Text(file.url.path)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onOpenInNewWindow) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app")
                    Text("在新窗口中编辑")
                }
                .font(.system(size: 12))
                .foregroundColor(themeManager.accent)
            }
            .buttonStyle(.plain)
            .help("使用 NSDocument 在新窗口打开并编辑该文件")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(themeManager.backgroundSecondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(themeManager.border),
            alignment: .bottom
        )
    }

    private var previewStatusBar: some View {
        HStack(spacing: 16) {
            Text("只读预览")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.textMuted)

            Spacer()

            Text("\(content.count) 字符 · \(content.components(separatedBy: .newlines).count) 行")
                .font(.system(size: 11))
                .foregroundColor(themeManager.textMuted)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(themeManager.backgroundSecondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(themeManager.border),
            alignment: .top
        )
    }
}
