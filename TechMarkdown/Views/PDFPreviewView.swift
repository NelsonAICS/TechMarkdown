import SwiftUI
import PDFKit

/// PDFKit 会在首次排版和容器尺寸变化时重算缩放比例。
/// 把工作区目标比例保存在视图自身，确保每次布局后都能稳定恢复用户选择。
final class WorkspacePDFView: PDFView {
    var workspaceZoom: CGFloat = 1 {
        didSet {
            needsLayout = true
            applyWorkspaceZoom()
        }
    }

    private var isApplyingWorkspaceZoom = false

    override func layout() {
        super.layout()
        applyWorkspaceZoom()
    }

    func applyWorkspaceZoom() {
        guard document != nil, !isApplyingWorkspaceZoom else { return }
        let fitScale = scaleFactorForSizeToFit
        guard fitScale > 0 else { return }

        let targetScale = fitScale * max(0.5, min(3, workspaceZoom))
        isApplyingWorkspaceZoom = true
        autoScales = false
        if abs(scaleFactor - targetScale) > 0.001 {
            scaleFactor = targetScale
        }
        autoScales = false
        isApplyingWorkspaceZoom = false
    }
}

struct PDFSelectionContext: Equatable {
    var text: String = ""
    var pageIndex: Int = 0
    var bounds: [CGRect] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// PDFKit 只读容器。显示的高亮来自本地批注数据库，不会写入源 PDF。
struct PDFPreviewView: NSViewRepresentable {
    let url: URL?
    let data: Data?
    let annotations: [Annotation]
    @Binding var selection: PDFSelectionContext
    @Binding var currentPage: Int
    @Binding var requestedPage: Int?
    let theme: TechTheme
    let zoom: CGFloat

    init(url: URL) {
        self.url = url
        self.data = nil
        self.annotations = []
        self._selection = .constant(PDFSelectionContext())
        self._currentPage = .constant(0)
        self._requestedPage = .constant(nil)
        self.theme = .dark
        self.zoom = 1
    }

    init(
        url: URL?,
        data: Data? = nil,
        annotations: [Annotation],
        selection: Binding<PDFSelectionContext>,
        currentPage: Binding<Int>,
        requestedPage: Binding<Int?>,
        theme: TechTheme,
        zoom: CGFloat = 1
    ) {
        self.url = url
        self.data = data
        self.annotations = annotations
        self._selection = selection
        self._currentPage = currentPage
        self._requestedPage = requestedPage
        self.theme = theme
        self.zoom = zoom
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WorkspacePDFView {
        let pdfView = WorkspacePDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        pdfView.backgroundColor = theme == .dark
            ? NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.15, alpha: 1)
            : NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.97, alpha: 1)
        context.coordinator.attach(to: pdfView)
        context.coordinator.loadDocument(in: pdfView, url: url, data: data)
        context.coordinator.applyZoom(zoom, to: pdfView)
        context.coordinator.applyAnnotations(annotations, to: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: WorkspacePDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadDocument(in: pdfView, url: url, data: data)
        context.coordinator.applyZoom(zoom, to: pdfView)
        context.coordinator.applyAnnotations(annotations, to: pdfView)
        pdfView.backgroundColor = theme == .dark
            ? NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.15, alpha: 1)
            : NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.97, alpha: 1)

        if let target = requestedPage,
           let document = pdfView.document,
           let page = document.page(at: target) {
            pdfView.go(to: page)
            DispatchQueue.main.async { requestedPage = nil }
        }
    }

    static func dismantleNSView(_ pdfView: WorkspacePDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        var parent: PDFPreviewView
        private weak var pdfView: PDFView?
        private var observers: [NSObjectProtocol] = []
        private var loadedIdentity = ""
        private var annotationFingerprint = ""
        private var findQuery = ""
        private var findMatches: [PDFSelection] = []
        private var findIndex = -1

        init(parent: PDFPreviewView) {
            self.parent = parent
        }

        func attach(to pdfView: PDFView) {
            self.pdfView = pdfView
            observers = [
                NotificationCenter.default.addObserver(
                    forName: .PDFViewSelectionChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in self?.captureSelection() },
                NotificationCenter.default.addObserver(
                    forName: .PDFViewPageChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in self?.captureCurrentPage() },
                NotificationCenter.default.addObserver(
                    forName: .findQueryChanged,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in self?.handleFindQueryChanged(notification) },
                NotificationCenter.default.addObserver(
                    forName: .performFindNext,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in self?.handleFindStep(notification, direction: 1) },
                NotificationCenter.default.addObserver(
                    forName: .performFindPrevious,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in self?.handleFindStep(notification, direction: -1) },
                NotificationCenter.default.addObserver(
                    forName: .findBarClosed,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in self?.clearFind() }
            ]
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        func loadDocument(in pdfView: PDFView, url: URL?, data: Data?) {
            let identity = data.map { "data:\($0.count):\($0.hashValue)" }
                ?? url?.standardizedFileURL.path
                ?? "empty"
            guard identity != loadedIdentity else { return }

            loadedIdentity = identity
            annotationFingerprint = ""
            if let data {
                pdfView.document = PDFDocument(data: data)
            } else if let url {
                pdfView.document = PDFDocument(url: url)
            } else {
                pdfView.document = nil
            }
            pdfView.autoScales = true
            captureCurrentPage()
            if !findQuery.isEmpty {
                performFind(findQuery)
            }
        }

        func applyZoom(_ zoom: CGFloat, to pdfView: PDFView) {
            let normalizedZoom = max(0.5, min(3, zoom))
            if let workspaceView = pdfView as? WorkspacePDFView {
                workspaceView.workspaceZoom = normalizedZoom
                return
            }

            guard pdfView.document != nil else { return }
            let fitScale = pdfView.scaleFactorForSizeToFit
            guard fitScale > 0 else { return }
            pdfView.autoScales = false
            pdfView.scaleFactor = fitScale * normalizedZoom
            pdfView.autoScales = false
        }

        func applyAnnotations(_ annotations: [Annotation], to pdfView: PDFView) {
            let pdfAnnotations = annotations.filter { $0.pdfAnchor != nil && !$0.resolved }
            let fingerprint = pdfAnnotations
                .map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970):\($0.resolved)" }
                .joined(separator: "|")
            guard fingerprint != annotationFingerprint, let document = pdfView.document else { return }
            annotationFingerprint = fingerprint

            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations where annotation.contents?.hasPrefix("techmarkdown:") == true {
                    page.removeAnnotation(annotation)
                }
            }

            for item in pdfAnnotations {
                guard
                    let anchor = item.pdfAnchor,
                    let page = document.page(at: anchor.pageIndex)
                else { continue }

                let marker = "techmarkdown:\(item.id.uuidString)"
                if anchor.bounds.isEmpty {
                    let pageBounds = page.bounds(for: .cropBox)
                    let noteBounds = CGRect(x: pageBounds.maxX - 34, y: pageBounds.maxY - 38, width: 22, height: 22)
                    let note = PDFAnnotation(bounds: noteBounds, forType: .text, withProperties: nil)
                    note.contents = marker
                    note.color = NSColor.systemBlue
                    page.addAnnotation(note)
                } else {
                    for bounds in anchor.bounds {
                        let highlight = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                        highlight.contents = marker
                        highlight.color = NSColor(calibratedRed: 0.97, green: 0.72, blue: 0.20, alpha: 0.42)
                        page.addAnnotation(highlight)
                    }
                }
            }
        }

        private func captureSelection() {
            guard
                let pdfView,
                let selection = pdfView.currentSelection,
                let document = pdfView.document,
                let page = selection.pages.first
            else {
                parent.selection = PDFSelectionContext()
                return
            }

            let pageIndex = document.index(for: page)
            let bounds = selection.selectionsByLine()
                .compactMap { line -> CGRect? in
                    guard line.pages.contains(page) else { return nil }
                    let rect = line.bounds(for: page)
                    return rect.isEmpty ? nil : rect
                }
            let nextSelection = PDFSelectionContext(
                text: selection.string ?? "",
                pageIndex: pageIndex,
                bounds: bounds
            )
            guard nextSelection != parent.selection else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.selection = nextSelection
            }
        }

        private func captureCurrentPage() {
            guard
                let pdfView,
                let document = pdfView.document,
                let page = pdfView.currentPage
            else { return }
            let nextPage = max(0, document.index(for: page))
            guard nextPage != parent.currentPage else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.currentPage = nextPage
            }
        }

        private func handleFindQueryChanged(_ notification: Notification) {
            guard notification.userInfo?["target"] as? FindTarget == .preview else { return }
            performFind(notification.userInfo?["query"] as? String ?? "")
        }

        private func handleFindStep(_ notification: Notification, direction: Int) {
            guard notification.userInfo?["target"] as? FindTarget == .preview else { return }
            let query = (notification.userInfo?["query"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                clearFind()
                return
            }
            if query != findQuery {
                performFind(query)
                return
            }
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex + direction + findMatches.count) % findMatches.count
            showCurrentFindMatch()
        }

        private func performFind(_ rawQuery: String) {
            guard let pdfView, let document = pdfView.document else { return }
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            findQuery = query
            guard !query.isEmpty else {
                clearFind()
                return
            }

            findMatches = document.findString(query, withOptions: .caseInsensitive)
            findMatches.forEach {
                $0.color = NSColor.systemYellow.withAlphaComponent(0.32)
            }
            pdfView.highlightedSelections = findMatches
            findIndex = findMatches.isEmpty ? -1 : 0
            showCurrentFindMatch()
        }

        private func showCurrentFindMatch() {
            guard let pdfView else { return }
            if findIndex >= 0, findIndex < findMatches.count {
                pdfView.go(to: findMatches[findIndex])
            }
            NotificationCenter.default.post(
                name: .findResultsUpdated,
                object: nil,
                userInfo: [
                    "current": findIndex >= 0 ? findIndex + 1 : 0,
                    "total": findMatches.count
                ]
            )
        }

        private func clearFind() {
            findQuery = ""
            findMatches = []
            findIndex = -1
            pdfView?.highlightedSelections = []
            NotificationCenter.default.post(
                name: .findResultsUpdated,
                object: nil,
                userInfo: ["current": 0, "total": 0]
            )
        }
    }
}

/// PDF 阅读工作区：阅读、选区高亮、页级笔记和加入 AI 对话。
struct PDFWorkspaceView: View {
    let fileURL: URL?
    let data: Data?
    let themeManager: ThemeManager
    let onAddToConversation: (String) -> Void

    @State private var selection = PDFSelectionContext()
    @State private var currentPage = 0
    @State private var requestedPage: Int?
    @State private var annotations: [Annotation] = []
    @State private var noteText = ""
    @State private var isComposingNote = false
    @State private var showNotes = true
    @State private var resolvedData: Data?
    @State private var isLoadingDocument = true
    @State private var loadError: String?
    @State private var reloadToken = UUID()

    private var path: String? { fileURL?.path }
    private var effectiveData: Data? { data ?? resolvedData }
    private var sourceIdentifier: String {
        let source = fileURL?.standardizedFileURL.path ?? "memory:\(data?.count ?? 0)"
        let payload = data.map { "\($0.count):\($0.hashValue)" } ?? "file"
        return "\(source):\(payload):\(reloadToken.uuidString)"
    }
    private var pdfAnnotations: [Annotation] {
        annotations.filter { $0.pdfAnchor != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                pdfContent

                if showNotes {
                    notesPanel
                        .frame(width: 250)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(themeManager.backgroundPrimary)
        .onAppear(perform: reloadAnnotations)
        .task(id: sourceIdentifier) {
            await loadPDFSource()
        }
        .onReceive(NotificationCenter.default.publisher(for: .annotationListChanged)) { notification in
            guard notification.userInfo?["path"] as? String == path else { return }
            reloadAnnotations()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigatePDFPage)) { notification in
            guard let page = notification.object as? Int else { return }
            requestedPage = page
        }
    }

    @ViewBuilder
    private var pdfContent: some View {
        if isLoadingDocument {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在加载 PDF…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(themeManager.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.backgroundPrimary)
        } else if let loadError {
            ContentUnavailableView {
                Label("无法显示 PDF", systemImage: "doc.badge.exclamationmark")
            } description: {
                Text(loadError)
            } actions: {
                Button("重新加载") {
                    reloadToken = UUID()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(themeManager.textSecondary)
            .background(themeManager.backgroundPrimary)
        } else if let effectiveData {
            PDFPreviewView(
                url: fileURL,
                data: effectiveData,
                annotations: pdfAnnotations,
                selection: $selection,
                currentPage: $currentPage,
                requestedPage: $requestedPage,
                theme: themeManager.theme,
                zoom: themeManager.previewZoom
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("没有可读取的 PDF 数据", systemImage: "doc.questionmark")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(themeManager.textSecondary)
                .background(themeManager.backgroundPrimary)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("PDF 只读", systemImage: "doc.richtext")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(themeManager.textPrimary)

            Text("第 \(currentPage + 1) 页")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(themeManager.textSecondary)

            if !selection.isEmpty {
                Text(selection.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.textMuted)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)

                Button("高亮") { addHighlight() }
                    .buttonStyle(.bordered)
                Button("添加笔记") { isComposingNote = true }
                    .buttonStyle(.borderedProminent)
                Button {
                    onAddToConversation(selection.text)
                } label: {
                    Label("加入对话", systemImage: "text.bubble")
                }
                .buttonStyle(.bordered)
            } else {
                Text("选择文字后可高亮、记笔记或加入对话")
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.textMuted)
                Button("当前页笔记") { isComposingNote = true }
                    .buttonStyle(.bordered)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showNotes.toggle() }
            } label: {
                Label("笔记 \(pdfAnnotations.count)", systemImage: "note.text")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(themeManager.backgroundSecondary)
        .overlay(alignment: .bottom) { Divider().overlay(themeManager.border) }
    }

    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PDF 笔记与高亮")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(themeManager.textPrimary)
                Spacer()
                Button {
                    isComposingNote = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            if isComposingNote {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selection.isEmpty ? "第 \(currentPage + 1) 页" : "第 \(selection.pageIndex + 1) 页 · 已关联选区")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(themeManager.accentSecondary)
                    TextField("记录你的理解、问题或待办…", text: $noteText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...6)
                        .padding(8)
                        .background(themeManager.backgroundPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    HStack {
                        Button("取消") {
                            noteText = ""
                            isComposingNote = false
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("保存笔记") { saveNote() }
                            .buttonStyle(.borderedProminent)
                            .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .background(themeManager.backgroundTertiary.opacity(0.7))
            }

            Divider().overlay(themeManager.border)

            if pdfAnnotations.isEmpty {
                ContentUnavailableView(
                    "还没有 PDF 笔记",
                    systemImage: "highlighter",
                    description: Text("选中文字后添加高亮或笔记；内容会保存在本机。")
                )
                .foregroundStyle(themeManager.textMuted)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(pdfAnnotations) { annotation in
                            noteRow(annotation)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(themeManager.backgroundSecondary)
        .overlay(alignment: .leading) { Divider().overlay(themeManager.border) }
    }

    private func noteRow(_ annotation: Annotation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("第 \((annotation.pdfAnchor?.pageIndex ?? 0) + 1) 页")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(themeManager.accentSecondary)
                Spacer()
                Button {
                    AnnotationService.shared.deleteAnnotation(id: annotation.id, for: path)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(themeManager.textMuted)
                }
                .buttonStyle(.plain)
            }
            Text(annotation.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(themeManager.textPrimary)
                .multilineTextAlignment(.leading)
            if !annotation.selectedText.isEmpty {
                Text(annotation.selectedText.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 10))
                    .foregroundStyle(themeManager.textMuted)
                    .lineLimit(2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.backgroundPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(themeManager.border, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            requestedPage = annotation.pdfAnchor?.pageIndex
        }
    }

    private func addHighlight() {
        guard !selection.isEmpty else { return }
        let preview = selection.text.replacingOccurrences(of: "\n", with: " ").prefix(48)
        _ = AnnotationService.shared.addAnnotation(
            "高亮：\(preview)",
            selectedText: selection.text,
            context: "PDF 第 \(selection.pageIndex + 1) 页",
            pdfAnchor: PDFAnnotationAnchor(pageIndex: selection.pageIndex, bounds: selection.bounds),
            for: path
        )
        reloadAnnotations()
    }

    private func saveNote() {
        let pageIndex = selection.isEmpty ? currentPage : selection.pageIndex
        _ = AnnotationService.shared.addAnnotation(
            noteText,
            selectedText: selection.text,
            context: "PDF 第 \(pageIndex + 1) 页",
            pdfAnchor: PDFAnnotationAnchor(pageIndex: pageIndex, bounds: selection.bounds),
            allowOverlap: true,
            for: path
        )
        noteText = ""
        isComposingNote = false
        reloadAnnotations()
    }

    private func reloadAnnotations() {
        annotations = AnnotationService.shared.annotations(for: path)
    }

    @MainActor
    private func loadPDFSource() async {
        isLoadingDocument = true
        loadError = nil
        selection = PDFSelectionContext()
        currentPage = 0
        resolvedData = nil

        do {
            let bytes: Data
            if let data {
                bytes = data
            } else if let fileURL {
                bytes = try await ProjectManager.shared.readData(at: fileURL.path)
            } else {
                throw PDFWorkspaceLoadError.missingSource
            }

            guard let document = PDFDocument(data: bytes), document.pageCount > 0 else {
                throw PDFWorkspaceLoadError.invalidDocument
            }
            resolvedData = bytes
        } catch {
            loadError = error.localizedDescription
        }

        isLoadingDocument = false
    }
}

private enum PDFWorkspaceLoadError: LocalizedError {
    case missingSource
    case invalidDocument

    var errorDescription: String? {
        switch self {
        case .missingSource:
            return "没有找到 PDF 文件来源。"
        case .invalidDocument:
            return "文件不是有效的 PDF，或 PDF 中没有可显示的页面。"
        }
    }
}
