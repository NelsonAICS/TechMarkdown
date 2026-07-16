import Foundation
import UniformTypeIdentifiers

/// 主窗口中的一个标签页。
/// - 文档标签：对应当前 NSDocument（可编辑）。
/// - 预览标签：对应项目浏览器或 HTML 内部链接打开的文件（只读预览）。
struct DocumentTab: Identifiable, Equatable {
    let id: UUID
    var fileURL: URL?
    var title: String
    var format: DocumentFormat
    let state: DocumentState
    let isDocument: Bool
    var projectFile: ProjectFile?
    var isLoading: Bool = false
    var isPinned: Bool = false

    static func == (lhs: DocumentTab, rhs: DocumentTab) -> Bool {
        lhs.id == rhs.id
        && lhs.fileURL == rhs.fileURL
        && lhs.title == rhs.title
        && lhs.format == rhs.format
        && lhs.isDocument == rhs.isDocument
        && lhs.projectFile == rhs.projectFile
        && lhs.isLoading == rhs.isLoading
        && lhs.isPinned == rhs.isPinned
    }

    static func documentTab(state: DocumentState, fileURL: URL?) -> DocumentTab {
        let title = fileURL?.deletingPathExtension().lastPathComponent ?? "未命名"
        let format = fileURL.flatMap { DocumentFormat.forURL($0) } ?? .markdown
        return DocumentTab(
            id: UUID(),
            fileURL: fileURL,
            title: title,
            format: format,
            state: state,
            isDocument: true,
            projectFile: nil,
            isLoading: false
        )
    }

    static func previewTab(fileURL: URL, projectFile: ProjectFile? = nil) -> DocumentTab {
        let format = DocumentFormat.forURL(fileURL) ?? .markdown
        return DocumentTab(
            id: UUID(),
            fileURL: fileURL,
            title: fileURL.deletingPathExtension().lastPathComponent,
            format: format,
            state: DocumentState(),
            isDocument: false,
            projectFile: projectFile,
            isLoading: true
        )
    }
}
