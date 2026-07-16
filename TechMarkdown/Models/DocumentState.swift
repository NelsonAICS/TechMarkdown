import SwiftUI

/// 共享的文档状态，用于在编辑器、预览和 AI 面板之间传递当前文本与文件信息。
final class DocumentState: ObservableObject {
    @Published var text: String
    @Published var currentFileURL: URL?
    @Published var format: DocumentFormat

    init(text: String = "", currentFileURL: URL? = nil, format: DocumentFormat = .markdown) {
        self.text = text
        self.currentFileURL = currentFileURL
        self.format = format
    }
}
