import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var markdown: UTType {
        UTType(importedAs: "net.daringfireball.markdown")
    }
    
    static var latex: UTType {
        UTType(importedAs: "org.tug.tex")
    }
}

enum DocumentFormat: String, Codable, CaseIterable {
    case markdown
    case latex
    case html

    static func forURL(_ url: URL) -> DocumentFormat? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mkd": return .markdown
        case "tex", "latex": return .latex
        case "html", "htm": return .html
        default:
            return nil
        }
    }
}

struct MarkdownDocument: FileDocument {
    var text: String
    var format: DocumentFormat
    
    init(text: String = "# 未命名文档\n\n开始输入 Markdown...", format: DocumentFormat = .markdown) {
        self.text = text
        self.format = format
    }

    init(data: Data, format: DocumentFormat = .markdown) {
        self.text = String(data: data, encoding: .utf8) ?? ""
        self.format = format
    }
    
    static var readableContentTypes: [UTType] { [.plainText, .markdown, .latex, .html] }
    static var writableContentTypes: [UTType] { [.markdown, .plainText, .latex, .html] }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            self.init(data: data)
        } else {
            self.init(text: "")
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: encodedData())
    }

    func encodedData() -> Data {
        text.data(using: .utf8) ?? Data()
    }
}

extension MarkdownDocument {
    static func markdownTemplate() -> String {
        """
        # 未命名文档

        开始输入 Markdown 内容……
        """
    }

    static func latexTemplate() -> String {
        """
        \\documentclass{article}
        \\usepackage[UTF8]{ctex}
        \\usepackage{amsmath}
        \\usepackage{amssymb}
        \\usepackage{graphicx}
        \\usepackage{geometry}
        \\geometry{a4paper, margin=1in}

        \\title{未命名文档}
        \\author{作者}
        \\date{\\today}

        \\begin{document}

        \\maketitle

        \\begin{abstract}
        在这里输入摘要内容。
        \\end{abstract}

        \\section{引言}

        开始编写你的 LaTeX 文档……

        \\end{document}
        """
    }

    static func htmlTemplate() -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>未命名页面</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.6; padding: 40px; }
                h1 { color: #0f172a; }
            </style>
        </head>
        <body>
            <h1>未命名页面</h1>
            <p>开始编辑 HTML 内容……</p>
        </body>
        </html>
        """
    }
}
