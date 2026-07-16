import SwiftUI
import UniformTypeIdentifiers

enum BrowserTab: String, CaseIterable {
    case project = "项目"
    case file = "文件"
}

/// 新建文件/文件夹的请求对象
private struct NewItemRequest: Identifiable {
    let id = UUID()
    let isFolder: Bool
}

/// 项目/文件浏览器侧边栏视图
struct ProjectBrowserView: View {
    @State private var selectedTab: BrowserTab = .project
    @State private var projects: [Project] = []
    @State private var fileRoots: [Project] = []
    @State private var selectedProject: Project?
    @State private var expandedPaths: Set<String> = []
    @State private var directoryChildren: [String: [ProjectFile]] = [:]
    @State private var selectedPath: String? = nil
    @State private var hoveredPath: String? = nil
    @State private var errorMessage: String? = nil
    @State private var showImporter = false
    @State private var isLoading = false
    @State private var newItemRequest: NewItemRequest?
    @State private var newItemName: String = ""

    let agent: AIAgent
    var currentPreviewFile: ProjectFile? = nil
    var currentDocumentURL: URL? = nil
    var onOpenTextFile: (ProjectFile) -> Void = { _ in }
    var onOpenExternalFile: (ProjectFile) -> Void = { _ in }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            
            Divider()
            
            if selectedTab == .project {
                projectContent
            } else {
                fileContent
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: selectedTab) { _, _ in syncSelection(to: currentTargetPath()) }
        .onChange(of: currentPreviewFile) { _, _ in syncSelection(to: currentTargetPath()) }
        .onChange(of: currentDocumentURL) { _, _ in syncSelection(to: currentTargetPath()) }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImporter(result: result)
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selectedTab) {
                ForEach(BrowserTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .help("切换项目/文件")
            
            Spacer()

            if selectedTab == .file {
                Button(action: { showImporter = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("添加本地文件夹")

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新")
            }
        }
    }
    
    // MARK: - 项目 Tab
    
    @ViewBuilder
    private var projectContent: some View {
        if let selected = selectedProject {
            projectDetail(project: selected)
        } else if projects.isEmpty {
            emptyState(
                icon: "folder.badge.plus",
                title: "暂无项目",
                button: "导入文件夹",
                buttonAction: showImportProjectPanel
            )
        } else {
            projectList
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("项目")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                Button(action: showCreateProjectPanel) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("新建项目")

                Button(action: showImportProjectPanel) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("导入文件夹作为项目")

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("刷新")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(projects) { project in
                        ProjectRow(
                            project: project,
                            isSelected: selectedPath == project.url.path,
                            isHovered: hoveredPath == project.url.path,
                            onOpen: {
                                selectedProject = project
                                selectedPath = project.url.path
                            },
                            onAddToContext: {
                                Task { await agent.addProjectToContext(project: project) }
                            },
                            onRemove: {
                                ProjectManager.shared.removeProjectRoot(project.rootURL)
                                refresh()
                            },
                            onHover: { hovering in
                                hoveredPath = hovering ? project.url.path : nil
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
                .padding(.trailing, 12)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func projectDetail(project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    selectedProject = nil
                    selectedPath = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.caption2)
                        Text(project.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
                .help(project.url.path)

                Spacer()

                Button {
                    newItemRequest = NewItemRequest(isFolder: false)
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("新建文件")

                Button {
                    newItemRequest = NewItemRequest(isFolder: true)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("新建文件夹")

                Button {
                    Task { await agent.addProjectToContext(project: project) }
                } label: {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("将项目加入对话")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                FileTreeView(
                    directoryURL: project.url,
                    level: 0,
                    selectedPath: $selectedPath,
                    hoveredPath: $hoveredPath,
                    expandedPaths: $expandedPaths,
                    directoryChildren: $directoryChildren,
                    onOpen: openFile,
                    onAdd: addFileToContext,
                    onAddFolder: addFolderToContext
                )
                .padding(.trailing, 12)
            }
            .frame(maxHeight: .infinity)
        }
        .sheet(item: $newItemRequest) { request in
            newItemSheet(project: project, request: request)
        }
    }

    private func newItemSheet(project: Project, request: NewItemRequest) -> some View {
        VStack(spacing: 16) {
            Text(request.isFolder ? "新建文件夹" : "新建文件")
                .font(.headline)

            TextField("名称", text: $newItemName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            HStack(spacing: 12) {
                Button("取消", role: .cancel) {
                    newItemRequest = nil
                    newItemName = ""
                }

                Button("创建") {
                    createNewItem(in: project)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear {
            newItemName = ""
        }
    }

    // MARK: - 文件 Tab

    @ViewBuilder
    private var fileContent: some View {
        if fileRoots.isEmpty {
            emptyState(
                icon: "folder",
                title: "暂无本地文件夹",
                button: "添加本地文件夹",
                buttonAction: { showImporter = true }
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(fileRoots) { root in
                        RootRow(
                            root: root,
                            selectedPath: $selectedPath,
                            hoveredPath: $hoveredPath,
                            expandedPaths: $expandedPaths,
                            directoryChildren: $directoryChildren,
                            onOpen: openFile,
                            onAdd: addFileToContext,
                            onAddFolder: addFolderToContext,
                            onRemove: {
                                ProjectManager.shared.removeFileRoot(root.url)
                                refresh()
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
                .padding(.trailing, 12)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Empty State

    private func emptyState(icon: String, title: String, button: String, buttonAction: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(button, action: buttonAction)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: - Actions

    private func refresh() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let projects = ProjectManager.shared.listProjects()
            let fileRoots = ProjectManager.shared.listFileRoots()
            DispatchQueue.main.async {
                self.projects = projects
                self.fileRoots = fileRoots
                self.directoryChildren.removeAll()
                self.expandedPaths.removeAll()
                self.selectedPath = nil
                self.selectedProject = nil
                self.isLoading = false
                self.syncSelection(to: self.currentTargetPath())
            }
        }
    }

    private func currentTargetPath() -> String? {
        currentPreviewFile?.path ?? currentDocumentURL?.path
    }

    private func syncSelection(to path: String?) {
        guard let path = path else {
            selectedPath = nil
            return
        }

        selectedPath = path

        // 收集所有祖先目录路径
        var ancestors: [String] = []
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        let stopPaths: Set<String> = ["/", ""]
        while !stopPaths.contains(url.path) {
            ancestors.append(url.path)
            url = url.deletingLastPathComponent()
        }

        if selectedTab == .project {
            // 自动切换到包含该文件的项目详情
            if let project = projects.first(where: { path.hasPrefix($0.url.path) }) {
                selectedProject = project
                expandedPaths.insert(project.url.path)
            }
        } else if selectedTab == .file {
            if let root = fileRoots.first(where: { path.hasPrefix($0.url.path) }) {
                expandedPaths.insert(root.url.path)
            }
        }

        for ancestor in ancestors {
            expandedPaths.insert(ancestor)
        }
    }
    
    private func handleImporter(result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                if selectedTab == .project {
                    _ = try ProjectManager.shared.importProject(from: url)
                } else {
                    _ = try ProjectManager.shared.addFileRoot(url)
                }
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func showCreateProjectPanel() {
        let panel = NSSavePanel()
        panel.title = "新建项目"
        panel.nameFieldStringValue = "未命名项目"
        panel.prompt = "创建"
        panel.canCreateDirectories = true

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                _ = try ProjectManager.shared.createProject(at: url)
                self.refresh()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func showImportProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "导入文件夹作为项目"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.urls.first else { return }
            do {
                _ = try ProjectManager.shared.importProject(from: url)
                self.refresh()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func createNewItem(in project: Project) {
        let name = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        do {
            if newItemRequest?.isFolder == true {
                _ = try ProjectManager.shared.createFolder(in: project.url, named: name)
            } else {
                let url = try ProjectManager.shared.createFile(in: project.url, named: name)
                let lowerExt = url.pathExtension.lowercased()
                if lowerExt == "tex" {
                    let template = MarkdownDocument.latexTemplate()
                    try template.write(to: url, atomically: true, encoding: .utf8)
                } else if lowerExt == "html" || lowerExt == "htm" {
                    let template = MarkdownDocument.htmlTemplate()
                    try template.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            newItemName = ""
            newItemRequest = nil
            directoryChildren.removeAll()
            expandedPaths.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openFile(_ file: ProjectFile) {
        guard !file.isDirectory else { return }
        selectedPath = file.path
        let ext = file.url.pathExtension.lowercased()
        let textLikeExtensions: Set<String> = ["md", "markdown", "txt", "tex", "html", "htm"]
        if textLikeExtensions.contains(ext) {
            onOpenTextFile(file)
        } else {
            onOpenExternalFile(file)
        }
    }
    
    private func addFileToContext(_ file: ProjectFile) {
        guard !file.isDirectory else { return }
        selectedPath = file.path
        Task {
            await agent.addProjectFileToContext(path: file.path)
        }
    }
    
    private func addFolderToContext(_ file: ProjectFile) {
        guard file.isDirectory else { return }
        selectedPath = file.path
        Task {
            let files = ProjectManager.shared.listFiles(inDirectory: file.url, maxDepth: 2)
                .filter { !$0.isDirectory }
                .prefix(20)
            for projectFile in files {
                await agent.addProjectFileToContext(path: projectFile.path)
            }
        }
    }
}

// MARK: - Project Row

private struct ProjectRow: View {
    let project: Project
    let isSelected: Bool
    let isHovered: Bool
    let onOpen: () -> Void
    let onAddToContext: () -> Void
    let onRemove: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 12))
                Text(project.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .help(project.url.path)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected
                    ? Color.accentColor.opacity(0.15)
                    : (isHovered ? Color.gray.opacity(0.15) : Color.clear))
        .cornerRadius(6)
        .contextMenu {
            Button("打开项目") { onOpen() }
            Button("在 Finder 中显示") {
                NSWorkspace.shared.open(project.url)
            }
            Button("将项目加入对话") { onAddToContext() }
            Button("移除项目") { onRemove() }
        }
        .onHover { hovering in
            onHover(hovering)
        }
    }
}

// MARK: - Root Row

private struct RootRow: View {
    let root: Project
    @Binding var selectedPath: String?
    @Binding var hoveredPath: String?
    @Binding var expandedPaths: Set<String>
    @Binding var directoryChildren: [String: [ProjectFile]]
    let onOpen: (ProjectFile) -> Void
    let onAdd: (ProjectFile) -> Void
    let onAddFolder: (ProjectFile) -> Void
    let onRemove: () -> Void

    private var isExpanded: Bool { expandedPaths.contains(root.url.path) }
    private var isHovered: Bool { hoveredPath == root.url.path }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "folder")
                        .foregroundColor(.accentColor)
                    Text(root.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .help(root.url.path)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(selectedPath == root.url.path
                        ? Color.accentColor.opacity(0.15)
                        : (isHovered ? Color.gray.opacity(0.15) : Color.clear))
            .cornerRadius(6)
            .contextMenu {
                Button("移除文件夹") { onRemove() }
            }
            .onHover { hovering in
                hoveredPath = hovering ? root.url.path : nil
            }

            if isExpanded {
                FileTreeView(
                    directoryURL: root.url,
                    level: 1,
                    selectedPath: $selectedPath,
                    hoveredPath: $hoveredPath,
                    expandedPaths: $expandedPaths,
                    directoryChildren: $directoryChildren,
                    onOpen: onOpen,
                    onAdd: onAdd,
                    onAddFolder: onAddFolder
                )
            }
        }
    }
    
    private func toggle() {
        selectedPath = root.url.path
        if isExpanded {
            expandedPaths.remove(root.url.path)
        } else {
            expandedPaths.insert(root.url.path)
        }
    }
}

// MARK: - File Tree View

private struct FileTreeView: View {
    let directoryURL: URL
    let level: Int
    @Binding var selectedPath: String?
    @Binding var hoveredPath: String?
    @Binding var expandedPaths: Set<String>
    @Binding var directoryChildren: [String: [ProjectFile]]
    let onOpen: (ProjectFile) -> Void
    let onAdd: (ProjectFile) -> Void
    let onAddFolder: (ProjectFile) -> Void
    
    private var children: [ProjectFile] {
        directoryChildren[directoryURL.path] ?? []
    }
    
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(children) { file in
                FileTreeNode(
                    file: file,
                    level: level,
                    selectedPath: $selectedPath,
                    hoveredPath: $hoveredPath,
                    expandedPaths: $expandedPaths,
                    directoryChildren: $directoryChildren,
                    onOpen: onOpen,
                    onAdd: onAdd,
                    onAddFolder: onAddFolder
                )
            }
        }
        .onAppear {
            loadChildren()
        }
    }
    
    private func loadChildren() {
        guard directoryChildren[directoryURL.path] == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let children = ProjectManager.shared.listFiles(inDirectory: directoryURL, maxDepth: 0)
            DispatchQueue.main.async {
                directoryChildren[directoryURL.path] = children
            }
        }
    }
}

// MARK: - File Tree Node

private struct FileTreeNode: View {
    let file: ProjectFile
    let level: Int
    @Binding var selectedPath: String?
    @Binding var hoveredPath: String?
    @Binding var expandedPaths: Set<String>
    @Binding var directoryChildren: [String: [ProjectFile]]
    let onOpen: (ProjectFile) -> Void
    let onAdd: (ProjectFile) -> Void
    let onAddFolder: (ProjectFile) -> Void
    
    private var isExpanded: Bool { expandedPaths.contains(file.path) }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileRow(
                file: file,
                level: level,
                isSelected: selectedPath == file.path,
                isHovered: hoveredPath == file.path,
                isExpanded: file.isDirectory ? isExpanded : nil,
                onToggle: file.isDirectory ? toggle : nil,
                onOpen: { onOpen(file) },
                onAdd: { onAdd(file) },
                onAddFolder: { onAddFolder(file) },
                onSelect: { selectedPath = file.path },
                hoveredPath: $hoveredPath
            )
            
            if file.isDirectory && isExpanded {
                FileTreeView(
                    directoryURL: file.url,
                    level: level + 1,
                    selectedPath: $selectedPath,
                    hoveredPath: $hoveredPath,
                    expandedPaths: $expandedPaths,
                    directoryChildren: $directoryChildren,
                    onOpen: onOpen,
                    onAdd: onAdd,
                    onAddFolder: onAddFolder
                )
            }
        }
    }
    
    private func toggle() {
        selectedPath = file.path
        if isExpanded {
            expandedPaths.remove(file.path)
        } else {
            expandedPaths.insert(file.path)
        }
    }
}

// MARK: - File Row

private struct FileRow: View {
    let file: ProjectFile
    let level: Int
    let isSelected: Bool
    let isHovered: Bool
    let isExpanded: Bool?
    let onToggle: (() -> Void)?
    let onOpen: () -> Void
    let onAdd: () -> Void
    let onAddFolder: () -> Void
    let onSelect: () -> Void
    @Binding var hoveredPath: String?
    
    private var iconName: String {
        if file.isDirectory { return "folder" }
        if let type = file.contentType {
            if type == .pdf { return "doc.text" }
            if type == .plainText || type == .markdown || type == .html { return "doc.plaintext" }
            if type.conforms(to: .sourceCode) { return "doc.text.magnifyingglass" }
        }
        return "doc"
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                onSelect()
                if let toggle = onToggle {
                    toggle()
                } else {
                    onOpen()
                }
            }) {
                HStack(spacing: 2) {
                    if file.isDirectory, let _ = onToggle {
                        Image(systemName: isExpanded == true ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                    } else {
                        Spacer()
                            .frame(width: 14)
                    }
                    
                    Image(systemName: iconName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    
                    Text(file.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .help(file.name)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if file.isDirectory {
                Button(action: onAddFolder) {
                    Image(systemName: "plus.bubble")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("将文件夹下文件加入对话")
            } else {
                Button(action: onAdd) {
                    Image(systemName: "plus.bubble")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("加入对话上下文")
                
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.forward")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("打开文件")
            }
        }
        .padding(.leading, 8 + CGFloat(level) * 12)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(isSelected
                    ? Color.accentColor.opacity(0.15)
                    : (isHovered ? Color.gray.opacity(0.15) : Color.clear))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .contextMenu {
            if file.isDirectory {
                Button("将文件夹加入对话") { onAddFolder() }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
            } else {
                Button("加入对话") { onAdd() }
                Button("打开") { onOpen() }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
            }
        }
        .onHover { hovering in
            hoveredPath = hovering ? file.path : nil
        }
    }
}

// MARK: - AIAgent Extension

extension AIAgent {
    /// 将整个项目的文本文件批量加入对话上下文
    /// - Parameters:
    ///   - project: 要加入的项目
    ///   - maxFiles: 最大加入文件数，防止 token 爆炸
    func addProjectToContext(project: Project, maxFiles: Int = 20) async {
        let files = ProjectManager.shared.listFiles(inDirectory: project.url, maxDepth: 2)
            .filter { !$0.isDirectory && $0.isTextLike }
            .prefix(maxFiles)

        for file in files {
            await addProjectFileToContext(path: file.path)
        }
    }

    /// 使用文档解析服务读取项目文件，并加入对话上下文
    func addProjectFileToContext(path: String) async {
        let content: String
        do {
            content = try await DocumentRetrievalService.shared.extractText(from: path, maxLength: 50_000)
        } catch {
            do {
                content = try await ProjectManager.shared.readFile(at: path, maxLength: 50_000)
            } catch {
                await MainActor.run {
                    self.errorMessage = "引用文件失败: \(path)"
                }
                return
            }
        }
        
        let file = ReferencedFile(
            id: UUID(),
            path: path,
            contentPreview: content,
            isIncluded: true
        )
        await MainActor.run {
            if !referencedFiles.contains(where: { $0.path == path }) {
                referencedFiles.append(file)
            }
        }
    }
}
