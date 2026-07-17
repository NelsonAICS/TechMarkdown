import SwiftUI
import WebKit
import AppKit

struct PreviewView: NSViewRepresentable {
    @EnvironmentObject var documentState: DocumentState
    @Bindable var themeManager: ThemeManager
    var onAddToConversation: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        let messageHandler = MessageHandler(coordinator: context.coordinator)
        context.coordinator.messageHandler = messageHandler
        config.userContentController.add(messageHandler, name: "previewDoubleClickHandler")
        config.userContentController.add(messageHandler, name: "previewLinkHandler")
        config.userContentController.add(messageHandler, name: "previewAnnotationHandler")

        let webView = ContextMenuWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.onAddToConversation = self.onAddToConversation
        webView.onAddToConversation = { [weak coordinator = context.coordinator] text in
            coordinator?.didRequestAddSelectionToConversation(text)
        }

        loadTemplate(webView: webView)
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if let customWebView = webView as? ContextMenuWebView {
            context.coordinator.onAddToConversation = self.onAddToConversation
            customWebView.currentFileURL = documentState.currentFileURL
            customWebView.onAddToConversation = { [weak coordinator = context.coordinator] text in
                coordinator?.didRequestAddSelectionToConversation(text)
            }
        }
        context.coordinator.update(
            text: documentState.text,
            theme: themeManager.theme,
            zoom: themeManager.previewZoom,
            format: documentState.format,
            fileURL: documentState.currentFileURL
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func loadTemplate(webView: WKWebView) {
        let possibleURLs: [URL?] = [
            Bundle.main.url(forResource: "preview-template", withExtension: "html", subdirectory: "Resources"),
            Bundle.main.url(forResource: "preview-template", withExtension: "html"),
            Bundle.main.url(forResource: "preview-template", withExtension: "html", subdirectory: "TechMarkdown_TechMarkdown.bundle")
        ]
        guard let url = possibleURLs.compactMap({ $0 }).first,
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            webView.loadHTMLString("<html><body style='color:red'>无法加载预览模板</body></html>", baseURL: nil)
            return
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var messageHandler: MessageHandler?
        private var pendingText: String?
        private var pendingTheme: TechTheme?
        private var pendingZoom: CGFloat?
        private var pendingFormat: DocumentFormat = .markdown
        private var pendingFileURL: URL?
        private var isLoaded = false
        private var findQuery: String = ""
        private var lastRequestedText: String?
        private var lastRequestedFormat: DocumentFormat?
        private var renderWorkItem: DispatchWorkItem?
        var onAddToConversation: ((String) -> Void)?

        deinit {
            renderWorkItem?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollPreviewNotification(_:)),
                name: .scrollPreviewToHeading,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleFindQueryChanged(_:)),
                name: .findQueryChanged,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePerformFindNext(_:)),
                name: .performFindNext,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePerformFindPrevious(_:)),
                name: .performFindPrevious,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleFindBarClosed(_:)),
                name: .findBarClosed,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAnnotationsChanged(_:)),
                name: .annotationListChanged,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollToAnnotation(_:)),
                name: .scrollPreviewToAnnotation,
                object: nil
            )
        }

        func update(text: String, theme: TechTheme, zoom: CGFloat, format: DocumentFormat, fileURL: URL?) {
            let shouldRender = text != lastRequestedText || format != lastRequestedFormat
            pendingText = text
            pendingTheme = theme
            pendingZoom = zoom
            pendingFormat = format
            pendingFileURL = fileURL
            lastRequestedText = text
            lastRequestedFormat = format

            applyVisualPending()
            if shouldRender {
                scheduleRender()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            applyVisualPending()
            renderPendingText()
        }

        private func applyVisualPending() {
            guard isLoaded, let webView = webView else { return }

            if let theme = pendingTheme {
                webView.evaluateJavaScript("setTheme('\(theme.rawValue)')", completionHandler: nil)
                pendingTheme = nil
            }

            if let zoom = pendingZoom {
                webView.evaluateJavaScript("setZoom(\(zoom))", completionHandler: nil)
                pendingZoom = nil
            }

        }

        private func scheduleRender() {
            renderWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.renderPendingText()
            }
            renderWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        private func renderPendingText() {
            guard isLoaded, let webView, let text = pendingText else { return }
            renderWorkItem?.cancel()
            pendingText = nil

            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            let renderer: String
            switch pendingFormat {
            case .latex: renderer = "renderLaTeXSource"
            case .html: renderer = "renderHTMLSource"
            case .markdown: renderer = "renderMarkdown"
            case .pdf: renderer = "renderMarkdown"
            }
            webView.evaluateJavaScript("\(renderer)('\(escaped)')") { [weak self] _, _ in
                self?.applyAnnotations()
            }
        }

        private func applyAnnotations() {
            guard let webView = webView as? ContextMenuWebView else { return }
            webView.applyAnnotationHighlights()
        }

        @objc private func handleAnnotationsChanged(_ notification: Notification) {
            applyAnnotations()
        }

        @objc private func handleScrollToAnnotation(_ notification: Notification) {
            guard let annotation = notification.object as? Annotation,
                  let webView = webView else { return }
            let escaped = annotation.id.uuidString
            webView.evaluateJavaScript("scrollToAnnotation('\(escaped)')", completionHandler: nil)
        }

        // MARK: - Editor → preview

        func didRequestAddSelectionToConversation(_ text: String) {
            onAddToConversation?(text)
        }

        func didReceiveLink(href: String, type: String) {
            if type == "external" {
                if let url = URL(string: href) {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            guard type == "file" else { return }

            let baseDirectory = pendingFileURL?.deletingLastPathComponent()
            let resolved: URL?
            if href.hasPrefix("file://") {
                resolved = URL(string: href)
            } else {
                resolved = URL(string: href, relativeTo: baseDirectory)
            }
            guard let url = resolved else { return }
            NotificationCenter.default.post(name: .openFileInNewTab, object: url)
        }

        func didReceivePreviewDoubleClick(body: [String: String]) {
            let slug = body["id"] ?? ""
            let heading = body["heading"] ?? ""
            var target = slug
            if target.isEmpty, !heading.isEmpty {
                target = heading.markdownHeadingSlug()
            }
            NotificationCenter.default.post(name: .scrollEditorToHeading, object: target)
        }

        func didSelectAnnotation(id: String) {
            guard
                let uuid = UUID(uuidString: id),
                let path = pendingFileURL?.path,
                let annotation = AnnotationService.shared.annotations(for: path)
                    .first(where: { $0.id == uuid })
            else {
                return
            }
            NotificationCenter.default.post(name: .focusAnnotation, object: annotation)
        }

        // MARK: - Editor → preview

        @objc private func handleScrollPreviewNotification(_ notification: Notification) {
            guard let slug = notification.object as? String else { return }
            scrollToHeading(slug: slug)
        }

        func scrollToHeading(slug: String) {
            guard let webView = webView else { return }
            let escaped = slug
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("scrollToHeading('\(escaped)')", completionHandler: nil)
        }

        // MARK: - Find

        @objc private func handleFindQueryChanged(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let target = userInfo["target"] as? FindTarget,
                  target == .preview,
                  let webView = webView else { return }
            let query = userInfo["query"] as? String ?? ""
            findQuery = query
            performJSFind(in: webView, query: query, backwards: false)
        }

        @objc private func handlePerformFindNext(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let target = userInfo["target"] as? FindTarget,
                  target == .preview,
                  let webView = webView else { return }
            let query = userInfo["query"] as? String ?? ""
            guard !query.isEmpty else { return }
            findQuery = query
            performJSFind(in: webView, query: query, backwards: false)
        }

        @objc private func handlePerformFindPrevious(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let target = userInfo["target"] as? FindTarget,
                  target == .preview,
                  let webView = webView else { return }
            let query = userInfo["query"] as? String ?? ""
            guard !query.isEmpty else { return }
            findQuery = query
            performJSFind(in: webView, query: query, backwards: true)
        }

        private func performJSFind(in webView: WKWebView, query: String, backwards: Bool) {
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            let js = "findText('\(escaped)', \(backwards ? "true" : "false"))"
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("Preview find error: \(error.localizedDescription)")
                }
                guard let dict = result as? [String: Any],
                      let current = dict["current"] as? Int,
                      let total = dict["total"] as? Int else { return }
                NotificationCenter.default.post(
                    name: .findResultsUpdated,
                    object: nil,
                    userInfo: ["current": current, "total": total]
                )
            }
        }

        @objc private func handleFindBarClosed(_ notification: Notification) {
            guard let webView = webView else { return }
            findQuery = ""
            webView.evaluateJavaScript("clearFindHighlights()") { [weak self] _, _ in
                self?.postFindResultsUpdated(current: 0, total: 0)
            }
        }

        private func postFindResultsUpdated(current: Int, total: Int) {
            NotificationCenter.default.post(
                name: .findResultsUpdated,
                object: nil,
                userInfo: ["current": current, "total": total]
            )
        }
    }

    // 弱引用中转，避免 WKUserContentController 强持有 Coordinator
    final class ContextMenuWebView: WKWebView {
        var onAddToConversation: ((String) -> Void)?
        var currentFileURL: URL?

        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            super.willOpenMenu(menu, with: event)
            let titles = ["添加批注", "加入 AI 对话"]
            guard !menu.items.contains(where: { titles.contains($0.title) }) else { return }

            let annotationItem = NSMenuItem(
                title: "添加批注",
                action: #selector(addAnnotation),
                keyEquivalent: ""
            )
            annotationItem.target = self

            let aiItem = NSMenuItem(
                title: "加入 AI 对话",
                action: #selector(addSelectionToConversation),
                keyEquivalent: ""
            )
            aiItem.target = self

            menu.insertItem(annotationItem, at: 0)
            menu.insertItem(aiItem, at: 1)
            menu.insertItem(NSMenuItem.separator(), at: 2)
        }

        @objc private func addSelectionToConversation() {
            evaluateJavaScript("window.getSelection().toString()") { [weak self] result, error in
                guard let self = self else { return }
                if let text = result as? String, !text.isEmpty {
                    self.onAddToConversation?(text)
                }
            }
        }

        @objc private func addAnnotation() {
            let js = """
            (function() {
                var sel = window.getSelection();
                var text = (sel ? sel.toString() : '').trim();
                var context = '';
                if (sel && sel.rangeCount > 0) {
                    var node = sel.anchorNode;
                    var el = node && node.nodeType === 3 ? node.parentElement : node;
                    if (el) context = (el.textContent || '').trim();
                }
                return { text: text, context: context };
            })()
            """
            evaluateJavaScript(js) { result, error in
                guard let dict = result as? [String: String],
                      let selected = dict["text"], !selected.isEmpty else { return }
                let context = dict["context"] ?? ""
                let trimmedContext = String(context.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
                let draft = AnnotationDraft(
                    selectedText: selected.trimmingCharacters(in: .whitespacesAndNewlines),
                    context: trimmedContext,
                    rangeSnapshot: nil,
                    source: .preview
                )
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .requestAnnotationComposer, object: draft)
                }
            }
        }

        func applyAnnotationHighlights() {
            guard let path = currentFileURL?.path else { return }
            let annotations = AnnotationService.shared.annotations(for: path).filter { !$0.resolved }
            let payload = annotations.map { [
                "id": $0.id.uuidString,
                "selectedText": $0.selectedText,
                "text": $0.text
            ] }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            evaluateJavaScript("highlightAnnotations(\(json))", completionHandler: nil)
        }
    }

    final class MessageHandler: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "previewDoubleClickHandler",
               let body = message.body as? [String: String] {
                coordinator?.didReceivePreviewDoubleClick(body: body)
                return
            }
            if message.name == "previewLinkHandler",
               let body = message.body as? [String: String],
               let href = body["href"],
               let type = body["type"] {
                coordinator?.didReceiveLink(href: href, type: type)
                return
            }
            if message.name == "previewAnnotationHandler",
               let body = message.body as? [String: String],
               let id = body["id"] {
                coordinator?.didSelectAnnotation(id: id)
            }
        }
    }
}
