import SwiftUI
import WebKit
import AppKit

/// 将当前 Markdown 渲染为 HTML 后通过 NSPrintOperation 导出为 PDF。
final class DocumentPDFExporter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var saveURL: URL?
    private var theme: TechTheme = .dark
    private var zoom: CGFloat = 1.0
    private var text: String = ""
    private var rendererFunction: String = "renderMarkdown"

    /// 导出 Markdown 预览为 PDF。
    static func exportMarkdown(text: String, theme: TechTheme, zoom: CGFloat) {
        exportWebContent(text: text, theme: theme, zoom: zoom, renderer: "renderMarkdown")
    }

    /// 导出 HTML 预览为 PDF。
    static func exportHTML(text: String, theme: TechTheme, zoom: CGFloat) {
        exportWebContent(text: text, theme: theme, zoom: zoom, renderer: "renderHTMLSource")
    }

    private static func exportWebContent(text: String, theme: TechTheme, zoom: CGFloat, renderer: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "导出.pdf"
        panel.title = "导出 PDF"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let exporter = DocumentPDFExporter()
        exporter.start(text: text, theme: theme, zoom: zoom, saveURL: url, renderer: renderer)
    }

    private func start(text: String, theme: TechTheme, zoom: CGFloat, saveURL: URL, renderer: String) {
        self.rendererFunction = renderer
        self.text = text
        self.theme = theme
        self.zoom = zoom
        self.saveURL = saveURL

        let config = WKWebViewConfiguration()
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        // A4 72dpi 尺寸，打印时再按 printInfo 分页
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 595, height: 842), configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        // 将 WebView 加入一个离屏窗口，确保打印时已完成排版渲染
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderOut(nil)
        self.hostWindow = window

        let possibleURLs: [URL?] = [
            Bundle.main.url(forResource: "preview-template", withExtension: "html", subdirectory: "Resources"),
            Bundle.main.url(forResource: "preview-template", withExtension: "html"),
            Bundle.main.url(forResource: "preview-template", withExtension: "html", subdirectory: "TechMarkdown_TechMarkdown.bundle")
        ]

        guard let url = possibleURLs.compactMap({ $0 }).first,
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            showError("无法加载预览模板")
            return
        }

        webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        let script = "\(rendererFunction)('\(escaped)'); setTheme('\(theme.rawValue)'); setZoom(\(zoom));"
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            // 等待 KaTeX / highlight.js 完成渲染
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.printToPDF()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error.localizedDescription)
        cleanup()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error.localizedDescription)
        cleanup()
    }

    private func printToPDF() {
        guard let webView = webView, let saveURL = saveURL else { return }

        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 595.22, height: 841.85)
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        let dictionary = printInfo.dictionary()
        dictionary.setObject(saveURL, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)

        // WKWebView 必须使用 printOperation(with:) 才能正确渲染网页内容
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = true

        let success = operation.run()
        if !success {
            showError("PDF 生成失败")
        }

        cleanup()
    }

    private func cleanup() {
        self.webView?.navigationDelegate = nil
        self.webView = nil
        self.hostWindow?.close()
        self.hostWindow = nil
        self.saveURL = nil
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "导出 PDF 失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}
