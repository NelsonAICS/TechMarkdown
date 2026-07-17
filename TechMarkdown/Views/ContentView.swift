import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

enum EditorPreviewMode: String, CaseIterable, Identifiable {
    case editorOnly
    case previewOnly
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .editorOnly: return "编辑"
        case .previewOnly: return "预览"
        case .both: return "分屏"
        }
    }

    var icon: String {
        switch self {
        case .editorOnly: return "square.and.pencil"
        case .previewOnly: return "eye"
        case .both: return "rectangle.split.2x1"
        }
    }
}

enum FindTarget: String, CaseIterable, Identifiable {
    case editor
    case preview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .editor: return "编辑器"
        case .preview: return "预览"
        }
    }
}

struct ContentView: View {
    @Binding var document: MarkdownDocument
    var fileURL: URL?
    @Environment(ThemeManager.self) var themeManager
    @StateObject private var documentState = DocumentState()
    @State private var agent = AIAgent()
    @State private var showAI = true
    @State private var showSettings = false
    @State private var showPendingEditDiff = false
    @State private var pendingEditForDiff: PendingEdit?
    @State private var showFindBar = false
    @State private var findQuery = ""
    @State private var findTarget: FindTarget = .editor
    @State private var editorPreviewMode: EditorPreviewMode = {
        let raw = UserDefaults.standard.string(forKey: "techmarkdown.editorPreviewMode") ?? ""
        return EditorPreviewMode(rawValue: raw) ?? .both
    }()
    @State private var editorStatus = EditorStatusInfo(line: 1, column: 1, selectionLength: 0)
    @State private var tabs: [DocumentTab] = []
    @State private var selectedTabID: UUID?
    @State private var previewFile: ProjectFile?
    @State private var compiledPDFURL: URL?
    @State private var showCompiledPDFSheet = false
    @State private var showLaTeXSetup = false
    init(document: Binding<MarkdownDocument>, fileURL: URL?) {
        self._document = document
        self.fileURL = fileURL
    }

    var body: some View {
        applyModifiers(to: mainContent)
    }

    private func applyModifiers(to view: some View) -> some View {
        let sized = AnyView(view
            .preferredColorScheme(themeManager.theme == .dark ? .dark : .light)
            .background(themeManager.backgroundPrimary)
            .appWindowSize(
                defaultWidth: 1500,
                defaultHeight: 920,
                minWidth: 1100,
                minHeight: 720
            )
            .task {
                if let url = fileURL {
                    ProjectManager.shared.bookmarkFile(url)
                }
            }
        )

        let receiving = AnyView(sized
            .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in
                themeManager.applyZoom(0.1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in
                themeManager.applyZoom(-0.1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomReset)) { _ in
                themeManager.resetZoom()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showPendingEditDiff)) { notification in
                if let edit = notification.object as? PendingEdit {
                    pendingEditForDiff = edit
                    showPendingEditDiff = true
                    NotificationCenter.default.post(
                        name: .highlightPendingEditRanges,
                        object: highlightRanges(for: edit)
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportPDF)) { _ in
                exportPDF()
            }
            .onReceive(NotificationCenter.default.publisher(for: .saveDocument)) { _ in
                saveDocument()
            }
        )

        let receiving2 = AnyView(receiving
            .onReceive(NotificationCenter.default.publisher(for: .saveAsDocument)) { _ in
                saveDocumentAs()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleFindBar)) { _ in
                toggleFindBar()
            }
            .onReceive(NotificationCenter.default.publisher(for: .findNext)) { _ in
                if !showFindBar { showFindBar = true }
                NotificationCenter.default.post(
                    name: .performFindNext,
                    object: nil,
                    userInfo: ["query": findQuery, "target": findTarget]
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .findPrevious)) { _ in
                if !showFindBar { showFindBar = true }
                NotificationCenter.default.post(
                    name: .performFindPrevious,
                    object: nil,
                    userInfo: ["query": findQuery, "target": findTarget]
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .showLaTeXEnvironmentSetup)) { _ in
                showLaTeXSetup = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestAnnotationComposer)) { _ in
                showAI = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusAnnotation)) { _ in
                showAI = true
            }
        )

        let lifecycle = AnyView(receiving2
            .onAppear {
                detectAndApplyDocumentFormat()
                documentState.text = document.text
                documentState.format = document.format
                documentState.currentFileURL = fileURL
                initializeDocumentTab()
                loadSavedConfiguration()
                reconcileDocumentFileDate()
                if let url = fileURL {
                    MemoryService.shared.recordFileInteraction(path: url.path, text: document.text)
                }
                agent.updateCurrentFile(
                    path: fileURL?.path,
                    documentText: document.text
                )
            }
            .onChange(of: document.text) { _, newValue in
                documentState.text = newValue
                UserDefaults.standard.set(newValue, forKey: "techmarkdown.currentDocumentText")
            }
            .onChange(of: fileURL) { _, newURL in
                if let url = newURL {
                    document.format = DocumentFormat.forURL(url) ?? .markdown
                }
                documentState.format = document.format
                documentState.currentFileURL = newURL
                updateDocumentTabURL(newURL)
                agent.updateCurrentFile(
                    path: newURL?.path,
                    documentText: document.text
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFileInNewTab)) { notification in
                if let url = notification.object as? URL {
                    openTab(for: url)
                }
            }
            .onChange(of: editorPreviewMode) { _, _ in
                if showFindBar {
                    synchronizeFindTarget()
                    postFindQueryChanged()
                }
            }
            .onChange(of: findQuery) { _, _ in
                postFindQueryChanged()
            }
            .onChange(of: findTarget) { _, _ in
                postFindQueryChanged()
            }
            .onChange(of: showFindBar) { _, isVisible in
                if isVisible {
                    postFindQueryChanged()
                } else {
                    NotificationCenter.default.post(name: .findBarClosed, object: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .editorStatusChanged)) { notification in
                if let info = notification.object as? EditorStatusInfo {
                    editorStatus = info
                }
            }
        )

        return lifecycle
            .sheet(isPresented: $showPendingEditDiff) {
                diffSheetContent
            }
            .sheet(isPresented: $showSettings) {
                AISettingsView(agent: agent)
                    .frame(minWidth: 640, minHeight: 560)
            }
            .sheet(isPresented: $showCompiledPDFSheet) {
                compiledPDFSheetContent
            }
            .sheet(isPresented: $showLaTeXSetup) {
                LaTeXEnvironmentSetupView()
                    .frame(minWidth: 520, minHeight: 360)
            }
            .onChange(of: showPendingEditDiff) { _, isPresented in
                if !isPresented {
                    NotificationCenter.default.post(name: .clearPendingEditHighlight, object: nil)
                }
            }
    }

    @ViewBuilder
    private var diffSheetContent: some View {
        if let edit = pendingEditForDiff {
            DiffSheetView(
                originalText: edit.originalText,
                suggestedText: edit.suggestedText,
                themeManager: themeManager
            )
        }
    }

    @ViewBuilder
    private var compiledPDFSheetContent: some View {
        if let url = compiledPDFURL {
            CompiledPDFSheet(
                url: url,
                defaultName: (fileURL?.deletingPathExtension().lastPathComponent ?? "未命名") + ".pdf",
                onClose: { showCompiledPDFSheet = false }
            )
            .frame(minWidth: 640, minHeight: 720)
        }
    }

    private var mainContent: some View {
        MainSplitLayout(
            documentState: documentState,
            connectionStatus: agent.connectionStatus,
            theme: themeManager.theme,
            editorFontSize: themeManager.editorFontSize,
            previewZoom: themeManager.previewZoom,
            showAI: showAI,
            showFindBar: showFindBar,
            editorPreviewMode: editorPreviewMode,
            tabs: tabs,
            selectedTabID: selectedTabID,
            left: { AnyView(leftSidebar) },
            main: { AnyView(mainArea) },
            right: { AnyView(aiSidebar) }
        )
    }

    private var selectedTab: DocumentTab? {
        tabs.first { $0.id == selectedTabID }
    }

    private var mainArea: some View {
        VStack(spacing: 0) {
            tabBar

            if let tab = selectedTab, !tab.isDocument {
                previewTabHeader(for: tab)
            }

            workspaceTopBar

            if showFindBar {
                findBar
            }

            activeTabContent
        }
    }

    @ViewBuilder
    private var activeTabContent: some View {
        if selectedTab?.isDocument == true {
            if document.format == .pdf {
                PDFWorkspaceView(
                    fileURL: fileURL,
                    data: document.originalData,
                    themeManager: themeManager,
                    onAddToConversation: { agent.addSelectedTextSnippet($0) }
                )
            } else {
                editorPreviewArea
            }
        } else if let tab = selectedTab {
            previewTabContent(tab: tab)
        }
    }

    private var tabBar: some View {
        TabBarView(
            tabs: tabs,
            selectedID: selectedTabID,
            themeManager: themeManager,
            onSelect: { id in selectTab(id) },
            onClose: { id in closeTab(id) },
            onPin: { id in togglePin(id) },
            onCloseOthers: { id in closeOthers(except: id) },
            onCloseAll: { closeAll() },
            onCloseToRight: { id in closeToRight(of: id) }
        )
    }

    private func previewTabHeader(for tab: DocumentTab) -> some View {
        HStack(spacing: 12) {
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(themeManager.textPrimary)
                .lineLimit(1)

            if let path = tab.fileURL?.path {
                Text(path)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            if let file = tab.projectFile, tab.format != .pdf {
                Button {
                    openInNewWindowForEdit(file)
                } label: {
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
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(themeManager.backgroundSecondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(themeManager.border),
            alignment: .bottom
        )
    }

    private func previewTabContent(tab: DocumentTab) -> some View {
        Group {
            if tab.format == .pdf {
                PDFWorkspaceView(
                    fileURL: tab.fileURL,
                    data: nil,
                    themeManager: themeManager,
                    onAddToConversation: { agent.addSelectedTextSnippet($0) }
                )
            } else {
                ZStack {
                    PreviewView(themeManager: themeManager, onAddToConversation: { text in
                        agent.addSelectedTextSnippet(text)
                    })
                        .environmentObject(tab.state)
                    TableOfContentsView(themeManager: themeManager)
                        .environmentObject(tab.state)
                }
            }
        }
    }

    private var aiSidebar: some View {
        AISidebarView(agent: agent, documentText: activeDocumentText, themeManager: themeManager)
    }

    /// AI 始终跟随当前标签页。PDF 与普通预览均为只读，避免修改建议误写回源文件。
    private var activeDocumentText: Binding<String> {
        Binding(
            get: {
                guard let tab = selectedTab, !tab.isDocument else { return document.text }
                return tab.state.text
            },
            set: { newValue in
                guard selectedTab?.isDocument == true, document.format != .pdf else { return }
                document.text = newValue
            }
        )
    }

    // MARK: - Custom Split Layout

    struct MainSplitLayout: NSViewControllerRepresentable {
        @Environment(ThemeManager.self) var themeManager

        var documentState: DocumentState
        var connectionStatus: String
        var theme: TechTheme
        var editorFontSize: CGFloat
        var previewZoom: CGFloat
        var showAI: Bool
        var showFindBar: Bool
        var editorPreviewMode: EditorPreviewMode
        var tabs: [DocumentTab]
        var selectedTabID: UUID?
        var left: () -> AnyView
        var main: () -> AnyView
        var right: () -> AnyView

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeNSViewController(context: Context) -> NSSplitViewController {
            let splitVC = NSSplitViewController()
            splitVC.splitView.isVertical = true
            splitVC.splitView.dividerStyle = .thin

            let leftVC = NSHostingController(rootView: AnyView(left().environment(themeManager).environmentObject(documentState)))
            let mainVC = NSHostingController(rootView: AnyView(main().environment(themeManager).environmentObject(documentState)))
            let rightVC = NSHostingController(rootView: AnyView(right().environment(themeManager).environmentObject(documentState)))

            context.coordinator.hostingControllers = [leftVC, mainVC, rightVC]

            let leftItem = NSSplitViewItem(sidebarWithViewController: leftVC)
            leftItem.minimumThickness = 230
            leftItem.maximumThickness = 300
            leftItem.preferredThicknessFraction = 0.15

            let mainItem = NSSplitViewItem(viewController: mainVC)
            mainItem.minimumThickness = 520
            mainItem.preferredThicknessFraction = 0.67

            let rightItem = NSSplitViewItem(viewController: rightVC)
            rightItem.minimumThickness = 320
            rightItem.maximumThickness = 440
            rightItem.preferredThicknessFraction = 0.22

            splitVC.addSplitViewItem(leftItem)
            splitVC.addSplitViewItem(mainItem)
            splitVC.addSplitViewItem(rightItem)

            rightItem.isCollapsed = !showAI

            context.coordinator.lastTheme = theme
            context.coordinator.lastEditorFontSize = editorFontSize
            context.coordinator.lastPreviewZoom = previewZoom
            context.coordinator.lastShowAI = showAI
            context.coordinator.lastShowFindBar = showFindBar
            context.coordinator.lastEditorPreviewMode = editorPreviewMode
            context.coordinator.lastDocumentText = documentState.text
            context.coordinator.lastConnectionStatus = connectionStatus
            context.coordinator.lastTabs = tabs
            context.coordinator.lastSelectedTabID = selectedTabID

            return splitVC
        }

        func updateNSViewController(_ splitVC: NSSplitViewController, context: Context) {
            let coordinator = context.coordinator
            let themeChanged = coordinator.lastTheme != theme
            let fontSizeChanged = coordinator.lastEditorFontSize != editorFontSize
            let zoomChanged = coordinator.lastPreviewZoom != previewZoom
            let showAIChanged = coordinator.lastShowAI != showAI
            let showFindBarChanged = coordinator.lastShowFindBar != showFindBar
            let modeChanged = coordinator.lastEditorPreviewMode != editorPreviewMode
            let textChanged = coordinator.lastDocumentText != documentState.text
            let statusChanged = coordinator.lastConnectionStatus != connectionStatus
            let tabsChanged = coordinator.lastTabs != tabs
            let selectedTabChanged = coordinator.lastSelectedTabID != selectedTabID
            let previewChanged = tabsChanged || selectedTabChanged

            // 左侧栏随主题、文本统计、AI 连接状态或当前选中标签页变化更新
            if (themeChanged || textChanged || statusChanged || tabsChanged || selectedTabChanged), coordinator.hostingControllers.count > 0 {
                coordinator.hostingControllers[0].rootView = AnyView(left().environment(themeManager).environmentObject(documentState))
            }

            // 主区域随主题 / 字体 / 缩放 / AI 显隐 / 查找栏显隐 / 模式切换 / 预览文件变化更新（不随文本变化重建，避免编辑器失焦）
            if themeChanged || fontSizeChanged || zoomChanged || showAIChanged || showFindBarChanged || modeChanged || previewChanged, coordinator.hostingControllers.count > 1 {
                coordinator.hostingControllers[1].rootView = AnyView(main().environment(themeManager).environmentObject(documentState))
            }

            // 右侧 AI 栏随主题或显隐更新
            if themeChanged || showAIChanged, coordinator.hostingControllers.count > 2 {
                coordinator.hostingControllers[2].rootView = AnyView(right().environment(themeManager).environmentObject(documentState))
            }

            // 折叠/展开右侧栏
            if showAIChanged {
                let rightItem = splitVC.splitViewItems[2]
                rightItem.isCollapsed = !showAI
            }

            coordinator.lastTheme = theme
            coordinator.lastEditorFontSize = editorFontSize
            coordinator.lastPreviewZoom = previewZoom
            coordinator.lastShowAI = showAI
            coordinator.lastShowFindBar = showFindBar
            coordinator.lastEditorPreviewMode = editorPreviewMode
            coordinator.lastDocumentText = documentState.text
            coordinator.lastConnectionStatus = connectionStatus
            coordinator.lastTabs = tabs
            coordinator.lastSelectedTabID = selectedTabID
        }

        final class Coordinator: NSObject {
            var hostingControllers: [NSHostingController<AnyView>] = []
            var lastTheme: TechTheme?
            var lastEditorFontSize: CGFloat?
            var lastPreviewZoom: CGFloat?
            var lastShowAI: Bool?
            var lastShowFindBar: Bool?
            var lastEditorPreviewMode: EditorPreviewMode?
            var lastDocumentText: String?
            var lastConnectionStatus: String?
            var lastTabs: [DocumentTab] = []
            var lastSelectedTabID: UUID?
        }
    }

    // MARK: - Sidebar

    private var leftSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            statsSection
            editorSection
            aiSection
            projectSection
        }
        .padding(18)
        .frame(minWidth: 230, idealWidth: 250)
        .background(themeManager.backgroundPrimary)
    }
    
    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectBrowserView(
                agent: agent,
                currentPreviewFile: previewFile,
                currentDocumentURL: fileURL,
                onOpenTextFile: previewTextFile,
                onOpenExternalFile: openExternalFile
            )
        }
        .frame(minHeight: 180, maxHeight: .infinity)
        .background(themeManager.backgroundSecondary)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(themeManager.border, lineWidth: 1)
        )
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("文档统计", systemImage: "chart.bar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(themeManager.textPrimary)

            VStack(spacing: 10) {
                StatRow(label: "字符数", value: "\(document.text.count)", themeManager: themeManager)
                StatRow(label: "词数", value: "\(wordCount)", themeManager: themeManager)
                StatRow(label: "行数", value: "\(document.text.components(separatedBy: .newlines).count)", themeManager: themeManager)
            }
        }
        .padding(16)
        .background(themeManager.backgroundSecondary)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(themeManager.border, lineWidth: 1)
        )
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("编辑设置", systemImage: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(themeManager.textPrimary)

            HStack {
                Text("字体大小")
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.textSecondary)
                Spacer()
                Stepper(value: Bindable(themeManager).editorFontSize, in: 10...24, step: 1) {
                    Text("\(Int(themeManager.editorFontSize))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(themeManager.textPrimary)
                        .frame(minWidth: 26, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .background(themeManager.backgroundSecondary)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(themeManager.border, lineWidth: 1)
        )
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("AI 功能", systemImage: "brain.head.profile")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(themeManager.textPrimary)

            VStack(spacing: 8) {
                SidebarButton(
                    icon: showAI ? "brain.head.profile.fill" : "brain.head.profile",
                    label: showAI ? "隐藏 AI 侧边栏" : "显示 AI 侧边栏",
                    themeManager: themeManager
                ) {
                    showAI.toggle()
                }

                SidebarButton(
                    icon: "gearshape",
                    label: "AI 设置",
                    themeManager: themeManager
                ) {
                    showSettings = true
                }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(connectionDotColor)
                    .frame(width: 6, height: 6)
                Text(agent.connectionStatus)
                    .font(.system(size: 11))
                    .foregroundColor(connectionDotColor)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(16)
        .background(themeManager.backgroundSecondary)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(themeManager.border, lineWidth: 1)
        )
    }

    // MARK: - Editor / Preview

    private var markdownPreview: some View {
        ZStack {
            PreviewView(themeManager: themeManager, onAddToConversation: { text in
                agent.addSelectedTextSnippet(text)
            })
            TableOfContentsView(themeManager: themeManager)
        }
    }

    private var editorPreviewArea: some View {
        Group {
            switch editorPreviewMode {
            case .editorOnly:
                VStack(spacing: 0) {
                    editorView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    statusBar
                }
                .background(themeManager.backgroundPrimary)
            case .previewOnly:
                markdownPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(themeManager.backgroundPrimary)
            case .both:
                HSplitView {
                    VStack(spacing: 0) {
                        editorView
                            .frame(minWidth: 280)
                        statusBar
                    }
                    .background(themeManager.backgroundPrimary)

                    markdownPreview
                        .frame(minWidth: 280)
                        .background(themeManager.backgroundPrimary)
                }
                .background(themeManager.backgroundPrimary)
            }
        }
    }

    private var editorView: some View {
        EditorView(
            text: $document.text,
            themeManager: themeManager,
            onAddToConversation: { selectedText in
                agent.addSelectedTextSnippet(selectedText)
            }
        )
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text("行 \(editorStatus.line), 列 \(editorStatus.column)")
            if editorStatus.selectionLength > 0 {
                Text("选中 \(editorStatus.selectionLength) 字符")
            }
            Spacer()
            Text("\(wordCount) 词 · \(document.text.count) 字符 · \(document.text.components(separatedBy: .newlines).count) 行")
        }
        .font(.system(size: 11))
        .foregroundColor(themeManager.textMuted)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(themeManager.backgroundSecondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(themeManager.border),
            alignment: .top
        )
    }

    // MARK: - Top Bar

    /// 始终跟随当前标签页显示的工作区工具栏。
    /// 文件能力不同只影响左侧模式和保存/导出按钮，不影响查找、主题、AI 与缩放。
    private var workspaceTopBar: some View {
        HStack(spacing: 12) {
            if isEditableDocumentTab {
                viewModeButtons
            } else {
                readOnlyContextBadge
            }

            Spacer()

            HStack(spacing: 6) {
                if isEditableDocumentTab {
                    saveButton
                }
                findButton
                if isEditableDocumentTab {
                    exportPDFButton
                }

                toolbarDivider

                aiToggleButton
                themeToggleButton
                zoomGroup
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(themeManager.backgroundSecondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(themeManager.border),
            alignment: .bottom
        )
    }

    private var isEditableDocumentTab: Bool {
        selectedTab?.isDocument == true && document.format != .pdf
    }

    private var activeFormat: DocumentFormat {
        guard let tab = selectedTab else { return document.format }
        return tab.isDocument ? document.format : tab.format
    }

    private var readOnlyContextBadge: some View {
        Label(readOnlyContextTitle, systemImage: activeFormatIcon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(themeManager.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(themeManager.backgroundTertiary.opacity(0.72))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(themeManager.border, lineWidth: 1)
            }
    }

    private var readOnlyContextTitle: String {
        switch activeFormat {
        case .pdf: return "PDF 阅读"
        case .markdown: return "Markdown 预览"
        case .latex: return "LaTeX 预览"
        case .html: return "HTML 预览"
        }
    }

    private var activeFormatIcon: String {
        switch activeFormat {
        case .pdf: return "doc.richtext"
        case .markdown: return "doc.plaintext"
        case .latex: return "doc.text"
        case .html: return "safari"
        }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(themeManager.border)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
    }

    private var viewModeButtons: some View {
        HStack(spacing: 2) {
            ForEach(EditorPreviewMode.allCases) { mode in
                let selected = editorPreviewMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        editorPreviewMode = mode
                    }
                    UserDefaults.standard.set(mode.rawValue, forKey: "techmarkdown.editorPreviewMode")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        Text(mode.label)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .foregroundColor(
                        selected
                            ? themeManager.controlSelectedForeground
                            : themeManager.textSecondary
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? themeManager.controlSelectedBackground : Color.clear)
                    )
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(themeManager.controlSelectedBorder, lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.label)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(themeManager.backgroundTertiary.opacity(themeManager.theme == .dark ? 0.5 : 0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(themeManager.border, lineWidth: 1)
        )
    }

    private var saveButton: some View {
        WorkspaceToolbarButton(
            icon: "square.and.arrow.down",
            help: "保存 (⌘S)",
            themeManager: themeManager,
            action: saveDocument
        )
    }

    private var findButton: some View {
        WorkspaceToolbarButton(
            icon: "magnifyingglass",
            help: "查找 (⌘F)",
            isActive: showFindBar,
            themeManager: themeManager,
            action: toggleFindBar
        )
    }

    private var findBar: some View {
        HStack(spacing: 12) {
            if isEditableDocumentTab && editorPreviewMode == .both {
                Picker("", selection: $findTarget) {
                    ForEach(FindTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            TextField("查找…", text: $findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit {
                    NotificationCenter.default.post(
                        name: .performFindNext,
                        object: nil,
                        userInfo: ["query": findQuery, "target": findTarget]
                    )
                }

            Button(action: findPrevious) {
                Image(systemName: "chevron.up")
                    .foregroundColor(themeManager.textSecondary)
            }
            .help("上一个")

            Button(action: findNext) {
                Image(systemName: "chevron.down")
                    .foregroundColor(themeManager.textSecondary)
            }
            .help("下一个")

            FindResultLabel(query: $findQuery)
                .frame(minWidth: 44, alignment: .leading)

            Spacer()

            Button(action: toggleFindBar) {
                Image(systemName: "xmark")
                    .foregroundColor(themeManager.textSecondary)
            }
            .help("关闭查找")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(themeManager.backgroundSecondary)
    }

    private struct FindResultLabel: View {
        @Environment(ThemeManager.self) var themeManager
        @Binding var query: String
        @State private var current: Int = 0
        @State private var total: Int = 0

        var body: some View {
            Text(displayText)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(themeManager.textSecondary)
                .onReceive(NotificationCenter.default.publisher(for: .findResultsUpdated)) { notification in
                    current = notification.userInfo?["current"] as? Int ?? 0
                    total = notification.userInfo?["total"] as? Int ?? 0
                }
                .onReceive(NotificationCenter.default.publisher(for: .findBarClosed)) { _ in
                    current = 0
                    total = 0
                }
        }

        private var displayText: String {
            if total > 0 {
                return "\(current)/\(total)"
            }
            if !query.isEmpty && current == 0 && total == 0 {
                return "无结果"
            }
            return ""
        }
    }

    private var exportPDFButton: some View {
        WorkspaceToolbarButton(
            icon: document.format == .latex ? "doc.text" : "arrow.up.doc",
            help: document.format == .latex ? "编译并预览 PDF" : "导出 PDF",
            themeManager: themeManager,
            action: exportPDF
        )
    }

    private var aiToggleButton: some View {
        WorkspaceToolbarButton(
            icon: "brain.head.profile",
            help: "切换 AI 侧边栏",
            isActive: showAI,
            themeManager: themeManager,
            action: { showAI.toggle() }
        )
    }

    private var themeToggleButton: some View {
        WorkspaceToolbarButton(
            icon: themeManager.theme.icon,
            help: "切换主题",
            themeManager: themeManager,
            action: { themeManager.toggleTheme() }
        )
    }

    private var zoomGroup: some View {
        HStack(spacing: 4) {
            WorkspaceToolbarButton(
                icon: "minus.magnifyingglass",
                help: "缩小预览",
                compact: true,
                themeManager: themeManager,
                action: { themeManager.applyZoom(-0.1) }
            )

            Text("\(Int(themeManager.previewZoom * 100))%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(themeManager.textSecondary)
                .frame(width: 42)

            WorkspaceToolbarButton(
                icon: "plus.magnifyingglass",
                help: "放大预览",
                compact: true,
                themeManager: themeManager,
                action: { themeManager.applyZoom(0.1) }
            )
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(themeManager.backgroundTertiary.opacity(0.55))
        )
    }

    private var wordCount: Int {
        document.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    }

    private var connectionDotColor: Color {
        let status = agent.connectionStatus
        if status.contains("成功") {
            return themeManager.success
        } else if status.contains("失败") || status.contains("未配置") {
            return themeManager.error
        } else if status.contains("检测中") {
            return themeManager.warning
        }
        return themeManager.textMuted
    }

    private func exportPDF() {
        switch document.format {
        case .latex:
            guard LaTeXCompilerService.shared.canCompile else {
                showLaTeXSetup = true
                return
            }
            compileLaTeXAndShowPreview()
        case .html:
            DocumentPDFExporter.exportHTML(text: document.text, theme: themeManager.theme, zoom: themeManager.previewZoom)
        case .markdown:
            DocumentPDFExporter.exportMarkdown(text: document.text, theme: themeManager.theme, zoom: themeManager.previewZoom)
        case .pdf:
            break
        }
    }

    private func compileLaTeXAndShowPreview() {
        Task {
            do {
                let pdfURL = try await LaTeXCompilerService.shared.compile(text: document.text, fileURL: fileURL)
                await MainActor.run {
                    compiledPDFURL = pdfURL
                    showCompiledPDFSheet = true
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "LaTeX 编译错误"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "确定")
                    alert.runModal()
                }
            }
        }
    }

    private func detectAndApplyDocumentFormat() {
        if let url = fileURL {
            document.format = DocumentFormat.forURL(url) ?? .markdown
        }
        documentState.format = document.format
        documentState.currentFileURL = fileURL
    }

    private func currentNSDocument() -> NSDocument? {
        if let doc = NSDocumentController.shared.currentDocument {
            return doc
        }
        if let url = fileURL,
           let doc = NSDocumentController.shared.document(for: url) {
            return doc
        }
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first,
           let doc = window.windowController?.document as? NSDocument {
            return doc
        }
        return nil
    }

    private func saveDocument() {
        guard document.format != .pdf else { return }
        if let doc = currentNSDocument() {
            reconcileDocumentFileDate()
            doc.save(nil)
            if let url = fileURL {
                MemoryService.shared.recordFileInteraction(path: url.path, text: document.text)
            }
        } else {
            manualSaveAs()
        }
    }

    private func saveDocumentAs() {
        guard document.format != .pdf else { return }
        if let doc = currentNSDocument() {
            doc.saveAs(nil)
        } else {
            manualSaveAs()
        }
    }

    private func manualSaveAs() {
        let panel = NSSavePanel()
        let (defaultExt, contentTypes): (String, [UTType]) = {
            switch document.format {
            case .latex: return ("tex", [.latex, .plainText])
            case .html:  return ("html", [.html, .plainText])
            case .markdown: return ("md", [.markdown, .plainText])
            case .pdf: return ("pdf", [.pdf])
            }
        }()
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "未命名") + ".\(defaultExt)"
        panel.allowedContentTypes = contentTypes
        panel.title = "保存文档"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try document.text.write(to: url, atomically: true, encoding: .utf8)
                MemoryService.shared.recordFileInteraction(path: url.path, text: document.text)
                if let doc = currentNSDocument() {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    if let date = attrs?[.modificationDate] as? Date {
                        doc.fileModificationDate = date
                    }
                }
            } catch {
                agent.errorMessage = "保存失败: \(error.localizedDescription)"
            }
        }
    }

    private func reconcileDocumentFileDate() {
        guard let doc = currentNSDocument(), let url = fileURL else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let date = attrs?[.modificationDate] as? Date {
            doc.fileModificationDate = date
        }
    }

    // MARK: - 标签页管理

    private func initializeDocumentTab() {
        guard tabs.isEmpty else { return }
        let docTab = DocumentTab.documentTab(state: documentState, fileURL: fileURL)
        tabs = [docTab]
        selectedTabID = docTab.id
        previewFile = nil
    }

    private func updateDocumentTabURL(_ url: URL?) {
        guard !tabs.isEmpty else { return }
        tabs[0].fileURL = url
        tabs[0].title = url?.deletingPathExtension().lastPathComponent ?? "未命名"
        tabs[0].format = url.flatMap { DocumentFormat.forURL($0) } ?? .markdown
    }

    private func selectTab(_ id: UUID) {
        selectedTabID = id
        if let tab = selectedTab {
            previewFile = tab.isDocument ? nil : tab.projectFile
        }
        synchronizeFindTarget()
        postFindQueryChanged()
        syncActiveAIContext()
    }

    private func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), !tabs[index].isDocument else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            let newIndex = min(max(index - 1, 0), tabs.count - 1)
            if newIndex >= 0 {
                selectTab(tabs[newIndex].id)
            } else {
                selectedTabID = nil
                previewFile = nil
            }
        }
    }

    private func togglePin(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPinned.toggle()
    }

    private func closeOthers(except id: UUID) {
        let idsToClose = tabs.compactMap { tab in
            (tab.id != id && !tab.isDocument && !tab.isPinned) ? tab.id : nil
        }
        removeTabs(idsToClose)
    }

    private func closeAll() {
        let idsToClose = tabs.compactMap { tab in
            (!tab.isDocument && !tab.isPinned) ? tab.id : nil
        }
        removeTabs(idsToClose)
    }

    private func closeToRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let idsToClose = tabs[(index + 1)...].compactMap { tab in
            (!tab.isDocument && !tab.isPinned) ? tab.id : nil
        }
        removeTabs(idsToClose)
    }

    private func removeTabs(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let closedIDs = Set(ids)
        tabs.removeAll { closedIDs.contains($0.id) }
        if let selected = selectedTabID, closedIDs.contains(selected) {
            let remaining = tabs
            let newIndex = max(remaining.count - 1, 0)
            if newIndex < remaining.count {
                selectTab(remaining[newIndex].id)
            } else {
                selectedTabID = nil
                previewFile = nil
            }
        }
    }

    private func openTab(for file: ProjectFile) {
        if let existing = tabs.first(where: { $0.fileURL == file.url }) {
            selectTab(existing.id)
            return
        }

        let tab = DocumentTab.previewTab(fileURL: file.url, projectFile: file)
        tabs.append(tab)
        selectTab(tab.id)

        Task {
            do {
                let content: String
                if file.url.pathExtension.lowercased() == "pdf" {
                    content = try await DocumentRetrievalService.shared.extractText(from: file.path, maxLength: 5_000_000)
                } else {
                    content = try await ProjectManager.shared.readFile(at: file.path, maxLength: 5_000_000)
                }
                await MainActor.run {
                    if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
                        tabs[idx].state.text = content
                        tabs[idx].state.currentFileURL = file.url
                        tabs[idx].state.format = DocumentFormat.forURL(file.url) ?? .markdown
                        tabs[idx].isLoading = false
                    }
                    MemoryService.shared.recordFileInteraction(path: file.url.path, text: content)
                    if selectedTabID == tab.id { syncActiveAIContext() }
                }
            } catch {
                await MainActor.run {
                    if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
                        tabs[idx].isLoading = false
                    }
                    agent.errorMessage = "无法预览文件：\(error.localizedDescription)"
                }
            }
        }
    }

    private func openTab(for url: URL) {
        if let existing = tabs.first(where: { $0.fileURL == url }) {
            selectTab(existing.id)
            return
        }

        let projectFile = makeProjectFile(from: url)
        let tab = DocumentTab.previewTab(fileURL: url, projectFile: projectFile)
        tabs.append(tab)
        selectTab(tab.id)

        Task {
            do {
                let content: String
                if url.pathExtension.lowercased() == "pdf" {
                    content = try await DocumentRetrievalService.shared.extractText(from: url.path, maxLength: 5_000_000)
                } else {
                    content = try await ProjectManager.shared.readFile(at: url.path, maxLength: 5_000_000)
                }
                await MainActor.run {
                    if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
                        tabs[idx].state.text = content
                        tabs[idx].state.currentFileURL = url
                        tabs[idx].state.format = DocumentFormat.forURL(url) ?? .markdown
                        tabs[idx].isLoading = false
                    }
                    MemoryService.shared.recordFileInteraction(path: url.path, text: content)
                    if selectedTabID == tab.id { syncActiveAIContext() }
                }
            } catch {
                await MainActor.run {
                    if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
                        tabs[idx].isLoading = false
                    }
                    agent.errorMessage = "无法打开链接文件：\(error.localizedDescription)"
                }
            }
        }
    }

    private func makeProjectFile(from url: URL) -> ProjectFile {
        ProjectFile(
            name: url.lastPathComponent,
            url: url,
            path: url.path,
            isDirectory: false,
            depth: 0,
            contentType: UTType(filenameExtension: url.pathExtension)
        )
    }

    private func syncActiveAIContext() {
        guard let tab = selectedTab else { return }
        let text = tab.isDocument ? document.text : tab.state.text
        let url = tab.isDocument ? fileURL : tab.fileURL
        let format = tab.isDocument ? document.format : tab.format
        documentState.text = text
        documentState.currentFileURL = url
        documentState.format = format
        agent.updateCurrentFile(path: url?.path, documentText: text)
    }

    // MARK: - 从项目浏览器打开文件

    private func previewTextFile(_ file: ProjectFile) {
        openTab(for: file)
    }

    /// 在新窗口中使用 NSDocument 打开文件进行编辑
    /// 这是 macOS 文档的标准行为，由系统负责保存、版本和权限管理
    private func openInNewWindowForEdit(_ file: ProjectFile) {
        let accessURL = ProjectManager.shared.scopedRoot(for: file.url) ?? file.url
        let didStart = accessURL.startAccessingSecurityScopedResource()

        NSDocumentController.shared.openDocument(
            withContentsOf: file.url,
            display: true
        ) { document, documentWasAlreadyOpen, error in
            if didStart { accessURL.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                if let error = error {
                    self.agent.errorMessage = "无法打开文件：\(error.localizedDescription)"
                }
            }
        }
    }

    private func openExternalFile(_ file: ProjectFile) {
        let accessURL = ProjectManager.shared.scopedRoot(for: file.url) ?? file.url
        let didStart = accessURL.startAccessingSecurityScopedResource()
        NSWorkspace.shared.open(file.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if didStart { accessURL.stopAccessingSecurityScopedResource() }
            if let error = error {
                DispatchQueue.main.async {
                    self.agent.errorMessage = "无法打开文件：\(error.localizedDescription)"
                }
            }
        }
    }
    
    private func toggleFindBar() {
        withAnimation(.easeInOut(duration: 0.15)) {
            showFindBar.toggle()
        }
        if showFindBar {
            synchronizeFindTarget()
            postFindQueryChanged()
        } else {
            NotificationCenter.default.post(name: .findBarClosed, object: nil)
        }
    }

    private func synchronizeFindTarget() {
        guard isEditableDocumentTab else {
            findTarget = .preview
            return
        }
        switch editorPreviewMode {
        case .editorOnly:
            findTarget = .editor
        case .previewOnly:
            findTarget = .preview
        case .both:
            break
        }
    }

    private func findNext() {
        NotificationCenter.default.post(
            name: .performFindNext,
            object: nil,
            userInfo: ["query": findQuery, "target": findTarget]
        )
    }

    private func findPrevious() {
        NotificationCenter.default.post(
            name: .performFindPrevious,
            object: nil,
            userInfo: ["query": findQuery, "target": findTarget]
        )
    }

    private func postFindQueryChanged() {
        guard showFindBar else { return }
        NotificationCenter.default.post(
            name: .findQueryChanged,
            object: nil,
            userInfo: ["query": findQuery, "target": findTarget]
        )
    }

    private func highlightRanges(for edit: PendingEdit) -> [NSValue] {
        let diff = computeLineDiff(oldText: edit.originalText, newText: edit.suggestedText)
        let nsText = edit.originalText as NSString
        var ranges: [NSRange] = []
        var lastOldLine = 0

        for line in diff {
            switch line.type {
            case .removed:
                if let num = line.oldLineNumber, num > 0 {
                    ranges.append(nsText.rangeOfLineNumber(num - 1))
                    lastOldLine = num
                }
            case .added:
                let target = max(lastOldLine, 1)
                ranges.append(nsText.rangeOfLineNumber(target - 1))
            case .unchanged:
                if let num = line.oldLineNumber {
                    lastOldLine = num
                }
            }
        }

        // 过滤无效区域并合并相邻或重叠区域
        let validRanges = ranges.filter { $0.location != NSNotFound }
        let merged = validRanges.reduce(into: [NSRange]()) { result, range in
            if let last = result.last, NSIntersectionRange(last, range).length > 0 {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return merged as [NSValue]
    }

    private func loadSavedConfiguration() {
        if let data = UserDefaults.standard.data(forKey: "techmarkdown.aiConfig"),
           let config = try? JSONDecoder().decode(AIProviderConfiguration.self, from: data) {
            let apiKey = KeychainService.shared.load(account: config.apiKeyAccount) ?? ""
            agent.updateConfiguration(config, apiKey: apiKey)
            agent.checkConnection()
        } else {
            agent.connectionStatus = "未配置 API"
        }
    }
}

// MARK: - Workspace Toolbar

struct WorkspaceToolbarButton: View {
    let icon: String
    let help: String
    var isActive = false
    var compact = false
    @Bindable var themeManager: ThemeManager
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? themeManager.controlSelectedForeground : themeManager.textSecondary)
                .frame(width: compact ? 26 : 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(buttonBackground)
                )
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(themeManager.controlSelectedBorder, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
    }

    private var buttonBackground: Color {
        if isActive { return themeManager.controlSelectedBackground }
        if isHovered { return themeManager.backgroundTertiary.opacity(0.82) }
        return Color.clear
    }
}

// MARK: - Sidebar Helpers

struct SidebarButton: View {
    let icon: String
    let label: String
    @Bindable var themeManager: ThemeManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(themeManager.accent)
                    .frame(width: 20, alignment: .center)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.textSecondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    @Bindable var themeManager: ThemeManager

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(themeManager.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(themeManager.textPrimary)
                .frame(minWidth: 36, alignment: .trailing)
        }
    }
}

struct DiffSheetView: View {
    let originalText: String
    let suggestedText: String
    @Bindable var themeManager: ThemeManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("修改差异对比")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(themeManager.textPrimary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(themeManager.backgroundSecondary)

            DiffView(oldText: originalText, newText: suggestedText, themeManager: themeManager)
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(themeManager.backgroundPrimary)
    }
}

struct CompiledPDFSheet: View {
    let url: URL
    let defaultName: String
    let onClose: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编译后的 PDF")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("关闭") {
                    dismiss()
                    onClose()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            PDFPreviewView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Button("下载 PDF") {
                    downloadPDF()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 720)
    }

    private func downloadPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultName
        panel.title = "保存 PDF"
        panel.prompt = "下载"

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                dismiss()
                onClose()
            } catch {
                let alert = NSAlert()
                alert.messageText = "保存 PDF 失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
        }
    }
}

private extension NSString {
    func rangeOfLineNumber(_ lineNumber: Int) -> NSRange {
        var current = 0
        var found = NSRange(location: NSNotFound, length: 0)
        enumerateSubstrings(in: NSRange(location: 0, length: length), options: .byLines) { _, _, enclosingRange, stop in
            if current == lineNumber {
                found = enclosingRange
                stop.pointee = true
            }
            current += 1
        }
        return found
    }
}
