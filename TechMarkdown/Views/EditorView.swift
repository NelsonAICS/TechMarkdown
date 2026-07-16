import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    @EnvironmentObject var documentState: DocumentState
    @Bindable var themeManager: ThemeManager
    var onAddToConversation: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = EditorTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        configure(textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorTextView else { return }

        let targetText = documentState.text
        var needsAnnotationRefresh = false
        if textView.string != targetText {
            let selected = textView.selectedRanges
            textView.string = targetText
            textView.selectedRanges = selected
            needsAnnotationRefresh = true
        }

        configure(textView: textView)
        if textView.currentFileURL != documentState.currentFileURL {
            needsAnnotationRefresh = true
        }
        textView.currentFileURL = documentState.currentFileURL
        if context.coordinator.lastAnnotationTheme != themeManager.theme {
            context.coordinator.lastAnnotationTheme = themeManager.theme
            needsAnnotationRefresh = true
        }
        if needsAnnotationRefresh {
            textView.applyAnnotationHighlights()
        }
        scrollView.verticalRulerView?.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func configure(textView: EditorTextView) {
        textView.isRichText = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true

        textView.font = NSFont.monospacedSystemFont(ofSize: themeManager.editorFontSize, weight: .regular)
        textView.textColor = themeManager.textPrimary.nsColor
        textView.backgroundColor = themeManager.backgroundPrimary.nsColor
        textView.insertionPointColor = themeManager.accent.nsColor

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 0
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: textView.font as Any,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: textView.textColor as Any
        ]

        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 4
        textView.themeManager = themeManager
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorView
        weak var textView: EditorTextView?
        var lastAnnotationTheme: TechTheme?
        private var annotationRefreshWorkItem: DispatchWorkItem?

        init(_ parent: EditorView) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollEditorNotification(_:)),
                name: .scrollEditorToHeading,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleHighlightRanges(_:)),
                name: .highlightPendingEditRanges,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleClearHighlight(_:)),
                name: .clearPendingEditHighlight,
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
                name: .scrollEditorToAnnotation,
                object: nil
            )
        }

        deinit {
            annotationRefreshWorkItem?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            parent.text = textView.string
            scheduleAnnotationRefresh()
            notifyStatusChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.needsDisplay = true
            notifyStatusChange()
        }

        private func notifyStatusChange() {
            guard let textView = textView else { return }
            let text = textView.string as NSString
            let selected = textView.selectedRange()
            let caretLocation = min(selected.location, text.length)
            let lineRange = text.lineRange(for: NSRange(location: caretLocation, length: 0))
            let lineNumber = text.substring(with: NSRange(location: 0, length: lineRange.location)).components(separatedBy: "\n").count + 1
            let column = caretLocation - lineRange.location + 1
            let info = EditorStatusInfo(
                line: lineNumber,
                column: column,
                selectionLength: selected.length
            )
            NotificationCenter.default.post(name: .editorStatusChanged, object: info)
        }

        @objc func addSelectionToConversation(_ sender: NSMenuItem) {
            guard let textView = sender.representedObject as? EditorTextView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            let selected = (textView.string as NSString).substring(with: range)
            parent.onAddToConversation(selected)
        }

        @objc private func handleAnnotationsChanged(_ notification: Notification) {
            annotationRefreshWorkItem?.cancel()
            textView?.applyAnnotationHighlights()
        }

        @objc private func handleScrollToAnnotation(_ notification: Notification) {
            guard let annotation = notification.object as? Annotation,
                  let textView = textView else { return }
            guard let match = AnnotationLocator.locate(annotation, in: textView.string) else { return }
            let range = match.range
            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
        }

        private func scheduleAnnotationRefresh() {
            annotationRefreshWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.textView?.applyAnnotationHighlights()
            }
            annotationRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        }

        @objc func addAnnotationToTextView(_ sender: NSMenuItem) {
            guard let textView = sender.representedObject as? EditorTextView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            let nsText = textView.string as NSString
            let selected = nsText.substring(with: range)
            let context = nsText.substring(with: nsText.lineRange(for: range))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = rangeSnapshot(for: range, in: nsText)
            let draft = AnnotationDraft(
                selectedText: selected.trimmingCharacters(in: .whitespacesAndNewlines),
                context: context,
                rangeSnapshot: snapshot,
                source: .editor
            )
            NotificationCenter.default.post(name: .requestAnnotationComposer, object: draft)
        }

        private func rangeSnapshot(for range: NSRange, in nsText: NSString) -> AnnotationRangeSnapshot {
            let startLineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
            let endIndex = max(range.location, NSMaxRange(range) - 1)
            let endLineRange = nsText.lineRange(for: NSRange(location: endIndex, length: 0))
            let startLine = nsText.substring(with: NSRange(location: 0, length: startLineRange.location))
                .components(separatedBy: "\n").count + 1
            let endLine = nsText.substring(with: NSRange(location: 0, length: endLineRange.location))
                .components(separatedBy: "\n").count + 1
            let startColumn = range.location - startLineRange.location + 1
            let endColumn = NSMaxRange(range) - endLineRange.location
            return AnnotationRangeSnapshot(
                startLine: startLine,
                startColumn: startColumn,
                endLine: endLine,
                endColumn: endColumn
            )
        }

        // MARK: - Preview → editor

        @objc private func handleScrollEditorNotification(_ notification: Notification) {
            guard let slug = notification.object as? String,
                  let textView = textView else { return }
            scrollToHeading(slug: slug, in: textView)
        }

        @objc private func handleHighlightRanges(_ notification: Notification) {
            guard let ranges = notification.object as? [NSValue],
                  let textView = textView else { return }
            let nsRanges = ranges.map { $0.rangeValue }.filter { $0.location != NSNotFound }
            guard !nsRanges.isEmpty else { return }
            let union = nsRanges.dropFirst().reduce(nsRanges[0]) { NSUnionRange($0, $1) }
            textView.selectedRange = union
            textView.scrollRangeToVisible(union)
        }

        @objc private func handleClearHighlight(_ notification: Notification) {
            guard let textView = textView else { return }
            textView.selectedRanges = [NSRange(location: 0, length: 0) as NSValue]
        }

        // MARK: - Find

        private var findQuery: String = ""
        private var findMatches: [NSRange] = []
        private var findIndex: Int = 0

        @objc private func handleFindQueryChanged(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let target = userInfo["target"] as? FindTarget,
                  target == .editor else { return }
            let query = userInfo["query"] as? String ?? ""
            updateFindQuery(query)
        }

        @objc private func handlePerformFindNext(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let target = userInfo["target"] as? FindTarget,
                  target == .editor else { return }
            let query = userInfo["query"] as? String ?? ""
            if query != findQuery {
                updateFindQuery(query)
            }
            findNext()
        }

        @objc private func handlePerformFindPrevious(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let target = userInfo["target"] as? FindTarget,
                  target == .editor else { return }
            let query = userInfo["query"] as? String ?? ""
            if query != findQuery {
                updateFindQuery(query)
            }
            findPrevious()
        }

        @objc private func handleFindBarClosed(_ notification: Notification) {
            clearFind()
        }

        private func updateFindQuery(_ query: String) {
            findQuery = query
            guard let textView = textView, !query.isEmpty else {
                findMatches = []
                findIndex = 0
                postFindResultsUpdated()
                return
            }
            let text = textView.string as NSString
            var matches: [NSRange] = []
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let found = text.range(of: query, options: .caseInsensitive, range: searchRange)
                if found.location == NSNotFound { break }
                matches.append(found)
                searchRange = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
            }
            findMatches = matches
            findIndex = matches.isEmpty ? 0 : 0
            selectCurrentFindMatch()
            postFindResultsUpdated()
        }

        private func findNext() {
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex + 1) % findMatches.count
            selectCurrentFindMatch()
            postFindResultsUpdated()
        }

        private func findPrevious() {
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
            selectCurrentFindMatch()
            postFindResultsUpdated()
        }

        private func clearFind() {
            findMatches = []
            findIndex = 0
            guard let textView = textView else { return }
            textView.selectedRange = NSRange(location: 0, length: 0)
            postFindResultsUpdated()
        }

        private func selectCurrentFindMatch() {
            guard let textView = textView, !findMatches.isEmpty else { return }
            let range = findMatches[findIndex]
            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
        }

        private func postFindResultsUpdated() {
            let total = findMatches.count
            let current = total > 0 ? findIndex + 1 : 0
            NotificationCenter.default.post(
                name: .findResultsUpdated,
                object: nil,
                userInfo: ["current": current, "total": total]
            )
        }

        private func scrollToHeading(slug: String, in textView: EditorTextView) {
            let text = textView.string
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            var foundRange: NSRange?

            nsText.enumerateSubstrings(in: range, options: .byLines) { substring, lineRange, _, stop in
                guard let line = substring else { return }
                if let headingText = Self.headingText(from: line),
                   headingText.markdownHeadingSlug() == slug {
                    foundRange = lineRange
                    stop.pointee = true
                }
            }

            guard let targetRange = foundRange else { return }
            textView.scrollRangeToVisible(targetRange)
            textView.selectedRanges = [targetRange as NSValue]
        }

        static func headingText(from line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            let withoutPrefix = trimmed.drop(while: { $0 == "#" })
            guard withoutPrefix.hasPrefix(" ") else { return nil }
            return String(withoutPrefix.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // MARK: - Editor → preview

        func syncPreviewToNearestHeading(at point: NSPoint) {
            guard let textView = textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            // point 是 textView 坐标，需转换到 text container 坐标
            let containerPoint = NSPoint(
                x: point.x - textView.textContainerOrigin.x,
                y: point.y - textView.textContainerOrigin.y
            )
            let index = layoutManager.characterIndex(
                for: containerPoint,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            guard index != NSNotFound else { return }
            guard let slug = nearestHeadingSlug(at: index, in: textView.string) else { return }
            NotificationCenter.default.post(name: .scrollPreviewToHeading, object: slug)
        }

        private func nearestHeadingSlug(at index: Int, in text: String) -> String? {
            let nsText = text as NSString
            let safeIndex = max(0, min(index, nsText.length))
            let lineRange = nsText.lineRange(for: NSRange(location: safeIndex, length: 0))

            // 收集所有行及其 range
            var lineRanges: [NSRange] = []
            nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: .byLines) { _, substringRange, _, _ in
                lineRanges.append(substringRange)
            }

            guard let currentLineIndex = lineRanges.firstIndex(where: { NSLocationInRange(safeIndex, $0) }) else { return nil }

            for i in (0...currentLineIndex).reversed() {
                let line = nsText.substring(with: lineRanges[i])
                if let headingText = Self.headingText(from: line) {
                    return headingText.markdownHeadingSlug()
                }
            }

            // 兜底：用当前行文本做 slug（非标题段落）
            let currentLine = nsText.substring(with: lineRange)
            let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed.markdownHeadingSlug()
            }
            return nil
        }
    }
}

// MARK: - Editor Text View with Context Menu + double-click sync

final class EditorTextView: NSTextView {
    weak var coordinator: EditorView.Coordinator?
    weak var themeManager: ThemeManager?
    var currentFileURL: URL?

    func applyAnnotationHighlights() {
        guard let layoutManager = layoutManager else { return }
        let nsText = string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)

        guard let path = currentFileURL?.path else { return }
        let annotations = AnnotationService.shared.annotations(for: path)
        guard !annotations.isEmpty else { return }

        let isDark = themeManager?.theme == .dark
        // 暗色模式：白字 + 浅底 + 白下划线，避免显脏；亮色模式：自然配色
        let highlightColor = isDark
            ? NSColor.white.withAlphaComponent(0.12)
            : (themeManager?.annotationHighlight.nsColor ?? NSColor.systemOrange).withAlphaComponent(0.32)
        let underlineColor = isDark
            ? NSColor.white.withAlphaComponent(0.75)
            : (themeManager?.annotationActive.nsColor ?? NSColor.systemOrange).withAlphaComponent(0.85)

        for annotation in annotations where !annotation.resolved && !annotation.selectedText.isEmpty {
            guard let match = AnnotationLocator.locate(annotation, in: string) else { continue }
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: highlightColor,
                forCharacterRange: match.range
            )
            layoutManager.addTemporaryAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                forCharacterRange: match.range
            )
            layoutManager.addTemporaryAttribute(
                .underlineColor,
                value: underlineColor,
                forCharacterRange: match.range
            )
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCurrentLineHighlight()
    }

    private func drawCurrentLineHighlight() {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer,
              let themeManager = themeManager else { return }

        let insertionIndex = selectedRange().location
        let lineRange = (string as NSString).lineRange(for: NSRange(location: insertionIndex, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect = convert(rect, from: self)
        rect.origin.y += textContainerOrigin.y
        rect.size.width = bounds.width
        rect.size.height = max(rect.height, 20)

        let color = themeManager.accent.nsColor.withAlphaComponent(0.10)
        color.setFill()
        rect.fill()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let coordinator = coordinator,
              selectedRange().length > 0 else { return menu }

        let annotationItem = NSMenuItem(
            title: "添加批注",
            action: #selector(EditorView.Coordinator.addAnnotationToTextView(_:)),
            keyEquivalent: ""
        )
        annotationItem.target = coordinator
        annotationItem.representedObject = self

        let aiItem = NSMenuItem(
            title: "加入 AI 对话",
            action: #selector(EditorView.Coordinator.addSelectionToConversation(_:)),
            keyEquivalent: ""
        )
        aiItem.target = coordinator
        aiItem.representedObject = self

        if let menu = menu {
            menu.insertItem(annotationItem, at: 0)
            menu.insertItem(aiItem, at: 1)
            menu.insertItem(NSMenuItem.separator(), at: 2)
        } else {
            let newMenu = NSMenu()
            newMenu.addItem(annotationItem)
            newMenu.addItem(aiItem)
            return newMenu
        }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let coordinator = coordinator {
            let point = convert(event.locationInWindow, from: nil)
            coordinator.syncPreviewToNearestHeading(at: point)
        }
    }
}

// MARK: - Line Number Ruler

final class LineNumberRulerView: NSRulerView {
    private var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    }

    init(scrollView: NSScrollView, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        self.clientView = scrollView.documentView
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var requiredThickness: CGFloat {
        guard let textView = scrollView?.documentView as? NSTextView else { return 40 }
        let lineCount = (textView.string as NSString).components(separatedBy: "\n").count
        let digits = max(2, String(lineCount).count)
        let sample = String(repeating: "8", count: digits)
        let size = sample.size(withAttributes: [.font: font])
        return max(40, size.width + 16)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = scrollView?.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let textColor = NSColor.secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        let visibleRect = scrollView?.documentVisibleRect ?? textView.bounds
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        let text = textView.string as NSString
        let lineRange = text.lineRange(for: visibleCharRange)
        var lineStart = lineRange.location
        var lineNumber = text.substring(with: NSRange(location: 0, length: lineStart)).components(separatedBy: "\n").count + 1

        while lineStart < NSMaxRange(visibleCharRange) {
            let charRange = NSRange(location: lineStart, length: 0)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect = convert(rect, from: textView)

            let label = "\(lineNumber)"
            let size = label.size(withAttributes: attrs)
            let point = NSPoint(
                x: bounds.width - size.width - 8,
                y: rect.minY + textView.textContainerInset.height
            )
            label.draw(at: point, withAttributes: attrs)

            lineNumber += 1
            let currentLineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(currentLineRange)
        }
    }
}

// MARK: - Color Helpers

extension Color {
    var nsColor: NSColor {
        return NSColor(self)
    }
}

// MARK: - Status Info

struct EditorStatusInfo {
    let line: Int
    let column: Int
    let selectionLength: Int
}

extension Notification.Name {
    static let editorStatusChanged = Notification.Name("editorStatusChanged")
}
