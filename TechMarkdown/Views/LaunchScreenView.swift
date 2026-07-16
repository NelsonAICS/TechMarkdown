import SwiftUI
import AppKit

/// 低合成开销的启动工作台。
///
/// 启动页是一个决策界面，不应持续占用 GPU。这里刻意使用静态渐变、实色面板和
/// 原生 SF Symbols，避免 TimelineView、blur、material 与 drawingGroup 叠加后
/// 造成的持续重绘和文字栅格化失真。
struct LaunchScreenView: View {
    @Environment(ThemeManager.self) private var themeManager

    let recentFiles: [FileIndexEntry]
    let recentProjects: [Project]
    let onOpenRecent: (FileIndexEntry) -> Void
    let onOpenRecentProject: (Project) -> Void
    let onNewMarkdown: () -> Void
    let onNewLaTeX: () -> Void
    let onNewHTML: () -> Void
    let onOpenFile: () -> Void
    let onOpenFolder: () -> Void
    let onClearRecent: () -> Void

    @State private var hoveredFileID: UUID?
    @State private var hoveredProjectID: UUID?
    @State private var hoveredActionID: String?

    var body: some View {
        HStack(spacing: 0) {
            welcomeRail
                .frame(width: 286)

            Divider()
                .overlay(themeManager.border)

            workspace
        }
        .background(background)
        .preferredColorScheme(themeManager.theme == .dark ? .dark : .light)
    }

    // MARK: - Welcome rail

    private var welcomeRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            Text("把注意力留给内容")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(themeManager.textPrimary)
                .padding(.top, 34)

            Text("创建、打开或继续最近的本地文档。文件始终保存在你的 Mac 上。")
                .font(.system(size: 13))
                .foregroundStyle(themeManager.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            VStack(spacing: 10) {
                launchAction(
                    id: "new-markdown",
                    title: "新建 Markdown",
                    subtitle: "创建空白文档",
                    icon: "square.and.pencil",
                    isPrimary: true,
                    action: onNewMarkdown
                )

                launchAction(
                    id: "open-file",
                    title: "打开文件",
                    subtitle: "Markdown、LaTeX 或 HTML",
                    icon: "doc.badge.plus",
                    action: onOpenFile
                )

                launchAction(
                    id: "open-folder",
                    title: "打开文件夹",
                    subtitle: "添加为本地项目",
                    icon: "folder.badge.plus",
                    action: onOpenFolder
                )
            }
            .padding(.top, 32)

            HStack(spacing: 7) {
                Text("其他格式")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(themeManager.textMuted)

                Spacer(minLength: 0)

                compactFormatButton(
                    title: "LaTeX",
                    icon: "textformat.subscript",
                    action: onNewLaTeX
                )
                compactFormatButton(
                    title: "HTML",
                    icon: "chevron.left.forwardslash.chevron.right",
                    action: onNewHTML
                )
            }
            .padding(.top, 8)

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11, weight: .semibold))
                Text("本地优先 · 无需上传")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(themeManager.textMuted)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
        .background(themeManager.backgroundSecondary.opacity(0.72))
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.accent)
                    .frame(width: 38, height: 38)

                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(themeManager.backgroundPrimary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("TechMarkdown")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(themeManager.textPrimary)

                Text("LOCAL WRITING DESK")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(themeManager.textMuted)
            }
        }
    }

    private func launchAction(
        id: String,
        title: String,
        subtitle: String,
        icon: String,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredActionID == id
        let foreground = isPrimary ? themeManager.backgroundPrimary : themeManager.textPrimary

        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .opacity(isPrimary ? 0.72 : 0.66)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(isHovered ? 0.9 : 0.45)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isPrimary
                            ? themeManager.accent
                            : themeManager.backgroundTertiary.opacity(isHovered ? 0.82 : 0.5)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isPrimary
                            ? themeManager.accent
                            : (isHovered ? themeManager.accent.opacity(0.7) : themeManager.border),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredActionID = hovering ? id : nil
        }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private func compactFormatButton(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(themeManager.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(themeManager.backgroundTertiary.opacity(0.46))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(themeManager.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新建 \(title)")
    }

    // MARK: - Recent workspace

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceHeader

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !recentProjects.isEmpty {
                        recentProjectsSection
                    }

                    recentFilesSection
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(themeManager.textPrimary)

            Text("从上次离开的地方继续，或者开始一篇新文档。")
                .font(.system(size: 12))
                .foregroundStyle(themeManager.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 30)
        .padding(.top, 30)
        .padding(.bottom, 24)
    }

    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "最近项目",
                count: recentProjects.count,
                icon: "folder"
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 12)],
                spacing: 12
            ) {
                ForEach(recentProjects.prefix(4)) { project in
                    projectCard(project)
                }
            }
        }
    }

    private func projectCard(_ project: Project) -> some View {
        let isHovered = hoveredProjectID == project.id

        return Button {
            onOpenRecentProject(project)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(themeManager.accent.opacity(0.14))
                        .frame(width: 36, height: 36)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(themeManager.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(themeManager.textPrimary)
                        .lineLimit(1)

                    Text(project.rootURL.deletingLastPathComponent().path)
                        .font(.system(size: 10))
                        .foregroundStyle(themeManager.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(themeManager.backgroundSecondary.opacity(isHovered ? 0.94 : 0.76))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(isHovered ? themeManager.accent.opacity(0.72) : themeManager.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredProjectID = hovering ? project.id : nil
        }
        .accessibilityLabel("项目 \(project.name)")
        .accessibilityHint("打开项目")
    }

    private var recentFilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader(
                    title: "最近文档",
                    count: recentFiles.count,
                    icon: "clock.arrow.circlepath"
                )

                Spacer()

                if !recentFiles.isEmpty {
                    Button(action: onClearRecent) {
                        Text("清除记录")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(themeManager.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("清除最近文档记录，不会删除本地文件")
                }
            }

            if recentFiles.isEmpty {
                emptyState
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 248, maximum: 360), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(recentFiles) { entry in
                        recentFileCard(entry)
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(themeManager.accent)

            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(themeManager.textPrimary)

            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(themeManager.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(themeManager.backgroundTertiary.opacity(0.6))
                )
        }
    }

    private func recentFileCard(_ entry: FileIndexEntry) -> some View {
        let isHovered = hoveredFileID == entry.id
        let indicator = indicatorColor(for: entry.path)

        return Button {
            onOpenRecent(entry)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: fileIcon(for: entry.path))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(indicator)
                        .frame(width: 18)

                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(themeManager.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(fileTypeLabel(for: entry.path))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(indicator)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(indicator.opacity(0.12))
                        )
                }

                Text(entry.summary.isEmpty ? entry.path : entry.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Text(formattedDate(entry.lastOpenedAt))
                    Text("·")
                    Text("\(entry.wordCount) 词")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(themeManager.textMuted)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(themeManager.backgroundSecondary.opacity(isHovered ? 0.96 : 0.78))
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(indicator)
                    .frame(width: 3)
                    .padding(.vertical, 12)
                    .opacity(isHovered ? 1 : 0.62)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(isHovered ? indicator.opacity(0.7) : themeManager.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredFileID = hovering ? entry.id : nil
        }
        .contextMenu {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title)，\(entry.summary)")
        .accessibilityHint("打开文档")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(themeManager.accent)

            Text("还没有最近文档")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(themeManager.textPrimary)

            Text("打开一个本地文件后，它会出现在这里。")
                .font(.system(size: 11))
                .foregroundStyle(themeManager.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(themeManager.backgroundSecondary.opacity(0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(themeManager.border, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        )
    }

    // MARK: - Background and helpers

    private var background: some View {
        ZStack {
            themeManager.backgroundPrimary

            LinearGradient(
                colors: [
                    themeManager.accentSecondary.opacity(0.07),
                    Color.clear,
                    themeManager.accent.opacity(0.04)
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )

            GeometryReader { geometry in
                Path { path in
                    let spacing: CGFloat = 48
                    for x in stride(from: 0, through: geometry.size.width, by: spacing) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    }
                    for y in stride(from: 0, through: geometry.size.height, by: spacing) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }
                .stroke(themeManager.textPrimary.opacity(0.018), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        default: return "晚上好"
        }
    }

    private func fileIcon(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "tex", "latex": return "textformat.subscript"
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "txt", "text": return "doc.plaintext"
        default: return "doc.text"
        }
    }

    private func fileTypeLabel(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "tex", "latex": return "TEX"
        case "html", "htm": return "HTML"
        case "txt", "text": return "TXT"
        default: return "MD"
        }
    }

    private func indicatorColor(for path: String) -> Color {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "tex", "latex": return themeManager.accentSecondary
        case "html", "htm": return Color(hex: "#6CA0DC")
        case "txt", "text": return themeManager.textMuted
        default: return themeManager.accent
        }
    }

    private func formattedDate(_ date: Date) -> String {
        Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()
}
