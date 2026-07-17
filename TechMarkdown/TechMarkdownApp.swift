import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ApplicationIconProvider {
    /// 直接读取应用包内由 AppIcon 资源集生成的 icns，避免 NSAlert 在图标缓存尚未就绪时显示系统占位图。
    static func load(from bundle: Bundle = .main) -> NSImage? {
        if let url = bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = false
            return image
        }

        // 开发预览或特殊测试宿主可能没有独立 icns，此时再使用应用包图标作为后备。
        let fallback = NSWorkspace.shared.icon(forFile: bundle.bundlePath)
        fallback.isTemplate = false
        return fallback
    }

    @MainActor
    static func installAsApplicationIcon() {
        guard let image = load() else { return }
        NSApplication.shared.applicationIconImage = image
    }
}

class TechMarkdownAppDelegate: NSObject, NSApplicationDelegate {
    private let launchWindowSize = NSSize(width: 980, height: 720)

    func applicationWillFinishLaunching(_ notification: Notification) {
        ApplicationIconProvider.installAsApplicationIcon()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // 阻止 DocumentGroup 在启动时自动创建空白文档或弹出打开面板；
        // 改为显示独立启动页窗口。
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ApplicationIconProvider.installAsApplicationIcon()
        DispatchQueue.main.async {
            self.resizeLaunchWindowIfNeeded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async {
            self.resizeLaunchWindowIfNeeded()
        }
        return true
    }

    /// 将启动页窗口强制调整为统一尺寸，避免首次启动与从 Dock 再次打开时大小不一致。
    private func resizeLaunchWindowIfNeeded() {
        guard let window = findLaunchWindow() else { return }
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let newFrame = NSRect(
            x: screenFrame.midX - launchWindowSize.width / 2,
            y: screenFrame.midY - launchWindowSize.height / 2,
            width: launchWindowSize.width,
            height: launchWindowSize.height
        )
        window.setFrame(newFrame, display: true, animate: false)
    }

    private func findLaunchWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue == "launch" || window.title == "TechMarkdown"
        }
    }
}

@main
struct TechMarkdownApp: App {
    @NSApplicationDelegateAdaptor(TechMarkdownAppDelegate.self) var appDelegate
    @State private var themeManager = ThemeManager()

    var body: some Scene {
        // 启动页窗口
        Window("TechMarkdown", id: "launch") {
            LaunchScreenContainer()
                .environment(themeManager)
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentSize)

        // 文档编辑器
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
                .environment(themeManager)
        }
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("保存") {
                    NotificationCenter.default.post(name: .saveDocument, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("另存为…") {
                    NotificationCenter.default.post(name: .saveAsDocument, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(before: .newItem) {
                Button("新建 LaTeX 文档") {
                    createNewLaTeXDocument()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("新建 HTML 文档") {
                    createNewHTMLDocument()
                }
            }

            CommandGroup(after: .textEditing) {
                Button("查找…") {
                    NotificationCenter.default.post(name: .toggleFindBar, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("查找下一个") {
                    NotificationCenter.default.post(name: .findNext, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("查找上一个") {
                    NotificationCenter.default.post(name: .findPrevious, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            CommandMenu("显示") {
                Button("切换主题") {
                    themeManager.toggleTheme()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("LaTeX 编译环境…") {
                    NotificationCenter.default.post(name: .showLaTeXEnvironmentSetup, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("放大") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("缩小") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("重置缩放") {
                    NotificationCenter.default.post(name: .zoomReset, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandGroup(after: .printItem) {
                Button("导出 PDF…") {
                    NotificationCenter.default.post(name: .exportPDF, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }

    private func createNewLaTeXDocument() {
        createTemplateDocument(
            template: MarkdownDocument.latexTemplate,
            defaultName: "未命名.tex",
            allowedTypes: [.latex, .plainText]
        )
    }

    private func createNewHTMLDocument() {
        createTemplateDocument(
            template: MarkdownDocument.htmlTemplate,
            defaultName: "未命名.html",
            allowedTypes: [.html, .plainText]
        )
    }
}

// MARK: - Launch Screen Container

struct LaunchScreenContainer: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(ThemeManager.self) var themeManager
    @State private var recentFilesToken = UUID()
    @State private var recentProjectsToken = UUID()

    var body: some View {
        LaunchScreenView(
            recentFiles: MemoryService.shared.recentFileIndexEntries(limit: 9),
            recentProjects: ProjectManager.shared.listProjects().reversed(),
            onOpenRecent: openRecentFile,
            onOpenRecentProject: openRecentProject,
            onNewMarkdown: createNewMarkdownDocument,
            onNewLaTeX: createNewLaTeXDocumentFromLaunch,
            onNewHTML: createNewHTMLDocumentFromLaunch,
            onOpenFile: openFileFromLaunch,
            onOpenFolder: openFolderFromLaunch,
            onClearRecent: clearRecentFiles
        )
        .id(recentFilesToken)
        .id(recentProjectsToken)
        .background(LaunchWindowCloseHandler())
    }

    private func clearRecentFiles() {
        MemoryService.shared.clearFileIndex()
        recentFilesToken = UUID()
    }

    private func dismissLaunchWindow() {
        LaunchWindowCloseHandler.isProgrammaticDismissal = true
        dismissWindow(id: "launch")
        // 延迟重置，确保 windowShouldClose 执行时标志仍为 true
        DispatchQueue.main.async {
            LaunchWindowCloseHandler.isProgrammaticDismissal = false
        }
    }

    private func createNewMarkdownDocument() {
        NSDocumentController.shared.newDocument(nil)
        dismissLaunchWindow()
    }

    private func createNewLaTeXDocumentFromLaunch() {
        createTemplateDocument(
            template: MarkdownDocument.latexTemplate,
            defaultName: "未命名.tex",
            allowedTypes: [.latex, .plainText]
        ) { _ in
            dismissLaunchWindow()
        }
    }

    private func createNewHTMLDocumentFromLaunch() {
        createTemplateDocument(
            template: MarkdownDocument.htmlTemplate,
            defaultName: "未命名.html",
            allowedTypes: [.html, .plainText]
        ) { _ in
            dismissLaunchWindow()
        }
    }

    private func openFileFromLaunch() {
        let panel = NSOpenPanel()
        panel.title = "打开文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .markdown, .latex, .html, .pdf]
        panel.prompt = "打开"

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }

            // 持久化该文件的安全书签，以便后续从最近文件列表中重新访问
            ProjectManager.shared.bookmarkFile(url)

            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error = error {
                    showAlert(message: "无法打开文件", info: error.localizedDescription)
                } else {
                    dismissLaunchWindow()
                }
            }
        }
    }

    private func openFolderFromLaunch() {
        let panel = NSOpenPanel()
        panel.title = "打开文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加为项目"

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let project = try ProjectManager.shared.importProject(from: url)
                self.openProject(project, dismissLaunch: true)
            } catch {
                showAlert(message: "无法添加项目文件夹", info: error.localizedDescription)
            }
        }
    }

    private func openRecentProject(_ project: Project) {
        openProject(project, dismissLaunch: true)
    }

    /// 打开项目：优先打开项目内第一个可编辑文本文件；如果没有则创建临时空白文档，
    /// 避免直接弹出「新建文件」保存面板。
    private func openProject(_ project: Project, dismissLaunch: Bool) {
        let files = ProjectManager.shared.listFiles(in: project, maxDepth: 1)
        let candidate = files.first { $0.isTextLike && !$0.isDirectory }

        if let file = candidate {
            let didStart = project.rootURL.startAccessingSecurityScopedResource()
            NSDocumentController.shared.openDocument(withContentsOf: file.url, display: true) { _, _, error in
                if didStart { project.rootURL.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async {
                    if let error = error {
                        showAlert(message: "无法打开项目文件", info: error.localizedDescription)
                    } else if dismissLaunch {
                        dismissLaunchWindow()
                    }
                }
            }
            return
        }

        // 无可编辑文件时，创建临时空白文档
        createTemporaryDocument(in: project.rootURL) { success in
            if success && dismissLaunch {
                dismissLaunchWindow()
            }
        }
    }

    private func createTemporaryDocument(in directoryURL: URL, completion: ((Bool) -> Void)? = nil) {
        let tempURL = directoryURL.appendingPathComponent("未命名.md")
        let finalURL: URL
        if FileManager.default.fileExists(atPath: tempURL.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let uniqueName = "未命名_\(formatter.string(from: Date())).md"
            finalURL = directoryURL.appendingPathComponent(uniqueName)
        } else {
            finalURL = tempURL
        }

        do {
            try MarkdownDocument.markdownTemplate().write(to: finalURL, atomically: true, encoding: .utf8)
            ProjectManager.shared.bookmarkFile(finalURL)
            NSDocumentController.shared.openDocument(withContentsOf: finalURL, display: true) { _, _, error in
                DispatchQueue.main.async {
                    if let error = error {
                        showAlert(message: "无法打开临时文档", info: error.localizedDescription)
                        completion?(false)
                    } else {
                        completion?(true)
                    }
                }
            }
        } catch {
            showAlert(message: "创建临时文档失败", info: error.localizedDescription)
            completion?(false)
        }
    }

    private func openRecentFile(_ entry: FileIndexEntry) {
        let url = URL(fileURLWithPath: entry.path)

        // 优先使用已授权的项目/文件根目录恢复访问权限
        if let scopedRoot = ProjectManager.shared.scopedRoot(for: url) {
            let didStart = scopedRoot.startAccessingSecurityScopedResource()
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if didStart { scopedRoot.stopAccessingSecurityScopedResource() }
                handleOpenRecentCompletion(error: error)
            }
            return
        }

        // 其次尝试使用该文件自身的安全书签
        if let bookmarkedURL = ProjectManager.shared.resolveBookmarkedFileURL(entry.path) {
            let didStart = bookmarkedURL.startAccessingSecurityScopedResource()
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if didStart { bookmarkedURL.stopAccessingSecurityScopedResource() }
                handleOpenRecentCompletion(error: error)
            }
            return
        }

        // 无可用授权时引导用户重新选择
        showAlert(
            message: "无法访问文件",
            info: "由于系统沙盒限制，TechMarkdown 需要重新授权才能访问该文件。请使用「打开文件」或「打开文件夹」重新选择。"
        )
    }

    private func handleOpenRecentCompletion(error: Error?) {
        if let error = error {
            showAlert(message: "无法打开最近文件", info: error.localizedDescription)
        } else {
            dismissLaunchWindow()
        }
    }
}

// MARK: - Shared Helpers

private func createTemplateDocument(
    template: @escaping () -> String,
    defaultName: String,
    allowedTypes: [UTType],
    completion: ((Bool) -> Void)? = nil
) {
    let panel = NSSavePanel()
    panel.title = "新建文档"
    panel.nameFieldStringValue = defaultName
    panel.allowedContentTypes = allowedTypes
    panel.canCreateDirectories = true
    panel.prompt = "创建"

    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        completion?(false)
        return
    }
    panel.beginSheetModal(for: window) { result in
        guard result == .OK, let url = panel.url else {
            completion?(false)
            return
        }
        do {
            try template().write(to: url, atomically: true, encoding: .utf8)
            ProjectManager.shared.bookmarkFile(url)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error = error {
                    showAlert(message: "无法打开新文档", info: error.localizedDescription)
                    completion?(false)
                } else {
                    completion?(true)
                }
            }
        } catch {
            showAlert(message: "创建文档失败", info: error.localizedDescription)
            completion?(false)
        }
    }
}

private func showAlert(message: String, info: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = info
    alert.alertStyle = .warning
    alert.addButton(withTitle: "确定")
    alert.runModal()
}

// MARK: - Launch Window Close Handler

/// 拦截启动页窗口的关闭事件，询问用户是最小化到 Dock 还是退出应用。
struct LaunchWindowCloseHandler: NSViewRepresentable {
    /// 当应用主动关闭启动页（如打开文件/项目）时设为 true，避免弹出确认对话框。
    static var isProgrammaticDismissal = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?

        func attach(to window: NSWindow?) {
            guard let window = window, self.window == nil else { return }
            self.window = window
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if LaunchWindowCloseHandler.isProgrammaticDismissal {
                LaunchWindowCloseHandler.isProgrammaticDismissal = false
                return true
            }

            let alert = NSAlert()
            alert.messageText = "退出 TechMarkdown？"
            alert.informativeText = "你可以选择最小化到 Dock，或完全退出应用。"
            alert.alertStyle = .informational
            alert.icon = ApplicationIconProvider.load()
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "最小化到 Dock")
            alert.addButton(withTitle: "取消")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // 退出
                NSApplication.shared.terminate(nil)
                return true
            case .alertSecondButtonReturn:
                // 最小化
                sender.miniaturize(nil)
                return false
            default:
                // 取消
                return false
            }
        }
    }
}

extension Notification.Name {
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let zoomReset = Notification.Name("zoomReset")

    static let exportPDF = Notification.Name("exportPDF")

    static let scrollPreviewToHeading = Notification.Name("scrollPreviewToHeading")
    static let scrollEditorToHeading = Notification.Name("scrollEditorToHeading")

    static let saveDocument = Notification.Name("saveDocument")
    static let saveAsDocument = Notification.Name("saveAsDocument")
    static let highlightPendingEditRanges = Notification.Name("highlightPendingEditRanges")
    static let clearPendingEditHighlight = Notification.Name("clearPendingEditHighlight")

    static let toggleFindBar = Notification.Name("toggleFindBar")
    static let findNext = Notification.Name("findNext")
    static let findPrevious = Notification.Name("findPrevious")
    static let findQueryChanged = Notification.Name("findQueryChanged")
    static let performFindNext = Notification.Name("performFindNext")
    static let performFindPrevious = Notification.Name("performFindPrevious")
    static let findBarClosed = Notification.Name("findBarClosed")
    static let findResultsUpdated = Notification.Name("findResultsUpdated")

    static let showLaTeXEnvironmentSetup = Notification.Name("showLaTeXEnvironmentSetup")
    static let openFileInNewTab = Notification.Name("openFileInNewTab")
}
