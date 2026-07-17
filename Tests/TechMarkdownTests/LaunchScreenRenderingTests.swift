import XCTest
import SwiftUI
import AppKit
import PDFKit
@testable import TechMarkdown

final class LaunchScreenRenderingTests: XCTestCase {
    @MainActor
    func testLaunchScreenRendersAtDefaultWindowSize() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TECHMARKDOWN_SNAPSHOT_PATH"] else {
            throw XCTSkip("Set TECHMARKDOWN_SNAPSHOT_PATH to generate a launch-screen snapshot.")
        }

        let now = Date()
        let files = (0..<6).map { index in
            FileIndexEntry(
                id: UUID(),
                path: "/Users/demo/Documents/Research/note-\(index).md",
                projectPath: "/Users/demo/Documents/Research",
                title: ["项目阅读指南", "数据流与记忆系统", "实验结果整理", "论文参考规划", "模块映射说明", "发布检查清单"][index],
                summary: "这是一段用于验证启动页排版、层级和文字清晰度的文档摘要。",
                tags: ["示例"],
                wordCount: 420 + index * 137,
                lastModified: now.addingTimeInterval(Double(-index * 1800)),
                lastOpenedAt: now.addingTimeInterval(Double(-index * 1800))
            )
        }
        let projects = [
            Project(
                name: "TechMarkdown",
                url: URL(fileURLWithPath: "/Users/demo/TechMarkdown"),
                rootURL: URL(fileURLWithPath: "/Users/demo/TechMarkdown")
            ),
            Project(
                name: "论文资料",
                url: URL(fileURLWithPath: "/Users/demo/Research"),
                rootURL: URL(fileURLWithPath: "/Users/demo/Research")
            )
        ]

        let rootView = LaunchScreenView(
            recentFiles: files,
            recentProjects: projects,
            onOpenRecent: { _ in },
            onOpenRecentProject: { _ in },
            onNewMarkdown: {},
            onNewLaTeX: {},
            onNewHTML: {},
            onOpenFile: {},
            onOpenFolder: {},
            onClearRecent: {}
        )
        .environment(ThemeManager())
        .frame(width: 980, height: 720)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 980, height: 720)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Unable to create bitmap representation.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Unable to encode snapshot as PNG.")
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertGreaterThan(pngData.count, 10_000)
    }

    @MainActor
    func testAnnotationWorkspaceRendersAtSidebarSize() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TECHMARKDOWN_ANNOTATION_SNAPSHOT_PATH"] else {
            throw XCTSkip("Set TECHMARKDOWN_ANNOTATION_SNAPSHOT_PATH to generate an annotation snapshot.")
        }

        let path = "/tmp/techmarkdown-annotation-snapshot.md"
        AnnotationService.shared.annotations(for: path).forEach {
            AnnotationService.shared.deleteAnnotation(id: $0.id, for: path)
        }
        let text = """
        # 实验计划

        这一段需要补充数据来源和判断依据。

        结论部分需要与前文保持一致。
        """
        let first = AnnotationService.shared.addAnnotation(
            "请补充数据来源，并说明样本筛选标准。",
            selectedText: "补充数据来源和判断依据",
            context: "这一段需要补充数据来源和判断依据。",
            rangeSnapshot: AnnotationRangeSnapshot(
                startLine: 3,
                startColumn: 5,
                endLine: 3,
                endColumn: 16
            ),
            for: path
        )
        _ = AnnotationService.shared.addAnnotation(
            "全文检查术语一致性。",
            for: path
        )
        defer {
            AnnotationService.shared.annotations(for: path).forEach {
                AnnotationService.shared.deleteAnnotation(id: $0.id, for: path)
            }
        }

        let state = DocumentState()
        state.text = text
        state.currentFileURL = URL(fileURLWithPath: path)
        let theme = ThemeManager()
        let agent = AIAgent()
        let rootView = AISidebarView(
            agent: agent,
            documentText: .constant(text),
            themeManager: theme
        )
        .environment(theme)
        .environmentObject(state)
        .frame(width: 400, height: 720)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 720)
        hostingView.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: .focusAnnotation, object: first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Unable to create bitmap representation.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Unable to encode snapshot as PNG.")
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertGreaterThan(pngData.count, 10_000)
    }

    @MainActor
    func testAgentRunTimelineRendersAttentionStates() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TECHMARKDOWN_AGENT_SNAPSHOT_PATH"] else {
            throw XCTSkip("Set TECHMARKDOWN_AGENT_SNAPSHOT_PATH to generate an agent timeline snapshot.")
        }

        let conversationID = UUID()
        let run = AgentRunRecord(
            conversationID: conversationID,
            threadID: "snapshot-thread",
            status: .awaitingApproval,
            checkpointMessageCount: 3,
            modelRoundCount: 2,
            toolCallCount: 2
        )
        let steps = [
            AgentRunStep(
                runID: run.id,
                sequence: 0,
                kind: .context,
                status: .completed,
                title: "读取当前论文与 2 个引用文件",
                detail: "正文 3,240 字；引用：实验记录.md、参考文献.md",
                endedAt: Date()
            ),
            AgentRunStep(
                runID: run.id,
                sequence: 1,
                kind: .toolCall,
                status: .completed,
                title: "检索项目资料",
                detail: "找到 8 个相关段落，已加入本轮上下文",
                toolName: "search_project",
                endedAt: Date()
            ),
            AgentRunStep(
                runID: run.id,
                sequence: 2,
                kind: .approval,
                status: .waiting,
                title: "等待确认文档修改",
                detail: """
                本轮主要目标：分析用户附加文件
                实际使用的主要资料：08-技术亮点速查卡.md
                目标选择依据：用户已主动附加文件，附件默认成为本轮主要分析对象
                工具决策：资料足够，未调用工具
                """
            )
        ]
        let theme = ThemeManager()
        let rootView = AgentRunTimelineView(
            run: run,
            steps: steps,
            themeManager: theme
        )
        .environment(theme)
        .padding(16)
        .frame(width: 400, height: 560, alignment: .top)
        .background(theme.backgroundPrimary)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 560)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Unable to create bitmap representation.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Unable to encode snapshot as PNG.")
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertGreaterThan(pngData.count, 8_000)
    }

    @MainActor
    func testMarkdownConversationRendersBlockStructureAndAttachment() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TECHMARKDOWN_MARKDOWN_SNAPSHOT_PATH"] else {
            throw XCTSkip("Set TECHMARKDOWN_MARKDOWN_SNAPSHOT_PATH to generate a Markdown conversation snapshot.")
        }

        let theme = ThemeManager()
        let attachment = ReferencedFile(
            id: UUID(),
            path: "/project/08-技术亮点速查卡.md",
            contentPreview: "附件内容",
            isIncluded: true
        )
        let user = ChatMessage(
            role: .user,
            content: "帮我总结一下这个文档",
            referencedFiles: [attachment]
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: """
            > 分析对象：08-技术亮点速查卡.md

            ## 核心结论

            这份速查卡聚焦 **七项技术亮点**，适合面试前快速复习。

            ### 建议阅读顺序

            1. 先理解数据流与记忆系统
            2. 再检查 RAG 检索路径
            3. 最后核对可观测性与验证结果

            | 主题 | 建议 |
            | --- | --- |
            | RAG | 关注检索质量 |
            | Agent | 关注工具可靠性 |
            """
        )
        let rootView = ScrollView {
            VStack(spacing: 16) {
                MessageBubble(message: user, themeManager: theme)
                MessageBubble(message: assistant, themeManager: theme)
            }
            .padding(16)
        }
        .environment(theme)
        .frame(width: 420, height: 700)
        .background(theme.backgroundPrimary)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Unable to create bitmap representation.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Unable to encode snapshot as PNG.")
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertGreaterThan(pngData.count, 10_000)
    }

    @MainActor
    func testLightMarkdownTableFillsMessageWidth() throws {
        let outputPath = ProcessInfo.processInfo.environment["TECHMARKDOWN_LIGHT_TABLE_SNAPSHOT_PATH"]
            ?? "/tmp/techmarkdown-light-table.png"

        let theme = ThemeManager()
        theme.theme = .light
        let rootView = MarkdownMessageView(
            content: """
            ## 项目概览

            | 维度 | 内容 |
            | --- | --- |
            | 定位 | 本地研究写作 Agent |
            | 核心能力 | PDF 阅读、批注与对话 |
            | 数据原则 | 源文件只读，批注单独保存 |
            """,
            themeManager: theme
        )
        .environment(theme)
        .padding(16)
        .frame(width: 400, height: 300, alignment: .top)
        .background(theme.backgroundSecondary)

        try render(rootView, width: 400, height: 300, to: outputPath, minimumBytes: 8_000)
    }

    @MainActor
    func testDarkMarkdownTableShowsStrongHeaderAndExpandableCells() throws {
        let outputPath = ProcessInfo.processInfo.environment["TECHMARKDOWN_DARK_TABLE_SNAPSHOT_PATH"]
            ?? "/tmp/techmarkdown-dark-table.png"

        let theme = ThemeManager()
        theme.theme = .dark
        let rootView = MarkdownMessageView(
            content: """
            ## 文档库构成（10 个文件）

            | 层级 | 文件 | 作用 |
            | --- | --- | --- |
            | 全景 | 08 技术亮点速查卡 | 5 分钟鸟瞰核心技术路线与研究结论 |
            | How（数据） | 02 数据流记忆 | 解释数据如何跨会话流转并保持可追溯性 |
            | 面试 | 05 总结面试、07 问答清单 | 电梯演讲、模拟问答和薄弱项复盘 |
            """,
            themeManager: theme
        )
        .environment(theme)
        .padding(16)
        .frame(width: 400, height: 360, alignment: .top)
        .background(theme.backgroundSecondary)

        try render(rootView, width: 400, height: 360, to: outputPath, minimumBytes: 8_000)
    }

    @MainActor
    func testWorkspaceToolbarSelectedStatesRenderInBothThemes() throws {
        for techTheme in TechTheme.allCases {
            let theme = ThemeManager()
            theme.theme = techTheme
            let outputPath = "/tmp/techmarkdown-workspace-toolbar-\(techTheme.rawValue).png"
            let rootView = HStack(spacing: 8) {
                WorkspaceToolbarButton(
                    icon: "magnifyingglass",
                    help: "查找",
                    isActive: true,
                    themeManager: theme,
                    action: {}
                )
                WorkspaceToolbarButton(
                    icon: techTheme.icon,
                    help: "切换主题",
                    themeManager: theme,
                    action: {}
                )
                WorkspaceToolbarButton(
                    icon: "brain.head.profile",
                    help: "AI 侧边栏",
                    isActive: true,
                    themeManager: theme,
                    action: {}
                )
            }
            .padding(12)
            .background(theme.backgroundSecondary)

            try render(rootView, width: 160, height: 56, to: outputPath, minimumBytes: 1_000)
        }
    }

    @MainActor
    func testTableCellDetailUsesScrollableFullContentLayout() throws {
        let outputPath = ProcessInfo.processInfo.environment["TECHMARKDOWN_TABLE_DETAIL_SNAPSHOT_PATH"]
            ?? "/tmp/techmarkdown-table-cell-detail.png"

        let theme = ThemeManager()
        theme.theme = .dark
        let detail = MarkdownTableCellDetail(
            rowIndex: 6,
            columnIndex: 2,
            columnTitle: "作用",
            rowTitle: "面试",
            content: Array(repeating: "这段完整内容用于验证长单元格不会被省略，并且可以在详情窗口中继续向下滚动阅读。", count: 12)
                .joined(separator: "\n\n")
        )
        let rootView = MarkdownTableCellDetailView(detail: detail, themeManager: theme)
            .environment(theme)
            .frame(width: 620, height: 460)

        try render(rootView, width: 620, height: 460, to: outputPath, minimumBytes: 12_000)
    }

    @MainActor
    func testPDFWorkspaceRendersReadingAndNotesUI() throws {
        let outputPath = ProcessInfo.processInfo.environment["TECHMARKDOWN_PDF_SNAPSHOT_PATH"]
            ?? "/tmp/techmarkdown-pdf-workspace.png"

        let path = "/tmp/techmarkdown-pdf-workspace-snapshot.pdf"
        let image = NSImage(size: NSSize(width: 595, height: 842))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        let title = NSAttributedString(
            string: "TechMarkdown PDF Research Notes",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 24),
                .foregroundColor: NSColor.black
            ]
        )
        title.draw(at: NSPoint(x: 52, y: 760))
        image.unlockFocus()

        let pdf = PDFDocument()
        guard let page = PDFPage(image: image) else { return XCTFail("Unable to make PDF page") }
        pdf.insert(page, at: 0)
        guard let data = pdf.dataRepresentation() else { return XCTFail("Unable to encode PDF") }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)

        AnnotationService.shared.annotations(for: path).forEach {
            AnnotationService.shared.deleteAnnotation(id: $0.id, for: path)
        }
        _ = AnnotationService.shared.addAnnotation(
            "核对这一页的研究结论与原始数据。",
            selectedText: "TechMarkdown PDF Research Notes",
            context: "PDF 第 1 页",
            pdfAnchor: PDFAnnotationAnchor(
                pageIndex: 0,
                bounds: [CGRect(x: 48, y: 750, width: 380, height: 34)]
            ),
            for: path
        )
        defer {
            AnnotationService.shared.annotations(for: path).forEach {
                AnnotationService.shared.deleteAnnotation(id: $0.id, for: path)
            }
        }

        let theme = ThemeManager()
        theme.theme = .light
        theme.previewZoom = 1.2
        let rootView = PDFWorkspaceView(
            fileURL: URL(fileURLWithPath: path),
            data: nil,
            themeManager: theme,
            onAddToConversation: { _ in }
        )
        .environment(theme)
        .frame(width: 920, height: 700)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 920, height: 700)
        hostingView.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(1.5)
        var renderedPDFView: PDFView?
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hostingView.layoutSubtreeIfNeeded()
            renderedPDFView = findSubview(PDFView.self, in: hostingView)
        } while Date() < deadline && (renderedPDFView?.document == nil || renderedPDFView?.autoScales == true)

        XCTAssertEqual(renderedPDFView?.document?.pageCount, 1)
        XCTAssertEqual(renderedPDFView?.autoScales, false)
        try renderHostingView(hostingView, to: outputPath, minimumBytes: 20_000)
    }

    @MainActor
    private func render<V: View>(
        _ view: V,
        width: CGFloat,
        height: CGFloat,
        to outputPath: String,
        minimumBytes: Int
    ) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.layoutSubtreeIfNeeded()
        try renderHostingView(hostingView, to: outputPath, minimumBytes: minimumBytes)
    }

    @MainActor
    private func renderHostingView<V: View>(
        _ hostingView: NSHostingView<V>,
        to outputPath: String,
        minimumBytes: Int
    ) throws {
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Unable to create bitmap representation.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Unable to encode snapshot as PNG.")
        }
        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertGreaterThan(pngData.count, minimumBytes)
    }

    private func findSubview<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = findSubview(type, in: subview) {
                return match
            }
        }
        return nil
    }
}
