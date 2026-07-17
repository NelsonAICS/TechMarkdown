import XCTest
import UniformTypeIdentifiers
@testable import TechMarkdown

final class MarkdownDocumentTests: XCTestCase {

    func testDefaultDocument() {
        let doc = MarkdownDocument()
        XCTAssertTrue(doc.text.contains("未命名文档"))
        XCTAssertEqual(doc.format, .markdown)
    }

    func testMarkdownDocumentDecodesUTF8Data() throws {
        let text = "# Hello\n\nWorld"
        let data = text.data(using: .utf8)!
        let doc = MarkdownDocument(data: data)
        XCTAssertEqual(doc.text, text)
        XCTAssertEqual(doc.format, .markdown)
    }

    func testMarkdownDocumentEncodesUTF8Data() throws {
        let doc = MarkdownDocument(text: "# Test", format: .markdown)
        let data = doc.encodedData()
        XCTAssertEqual(String(data: data, encoding: .utf8), "# Test")
    }

    func testLaTeXTemplateContainsDocumentClass() {
        let template = MarkdownDocument.latexTemplate()
        XCTAssertTrue(template.contains("\\documentclass"))
        XCTAssertTrue(template.contains("\\begin{document}"))
        XCTAssertTrue(template.contains("ctex"))
    }

    func testHTMLTemplateContainsDoctype() {
        let template = MarkdownDocument.htmlTemplate()
        XCTAssertTrue(template.contains("<!DOCTYPE html>"))
        XCTAssertTrue(template.contains("<html"))
        XCTAssertTrue(template.contains("</html>"))
    }

    func testReadableContentTypesContainsMarkdownLaTeXHTMLAndPDF() {
        let types = MarkdownDocument.readableContentTypes
        XCTAssertTrue(types.contains(.markdown))
        XCTAssertTrue(types.contains(.latex))
        XCTAssertTrue(types.contains(.html))
        XCTAssertTrue(types.contains(.plainText))
        XCTAssertTrue(types.contains(.pdf))
    }

    func testPDFDocumentPreservesOriginalBytes() {
        let bytes = Data("not-a-valid-pdf".utf8)
        let doc = MarkdownDocument(data: bytes, format: .pdf)
        XCTAssertEqual(doc.format, .pdf)
        XCTAssertEqual(doc.encodedData(), bytes)
        XCTAssertEqual(doc.text, "")
    }
}
