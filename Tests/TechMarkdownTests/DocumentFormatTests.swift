import XCTest
@testable import TechMarkdown

final class DocumentFormatTests: XCTestCase {

    func testMarkdownExtensions() {
        XCTAssertEqual(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.md")), .markdown)
        XCTAssertEqual(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.markdown")), .markdown)
        XCTAssertEqual(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.mkd")), .markdown)
    }

    func testLaTeXExtensions() {
        XCTAssertEqual(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.tex")), .latex)
        XCTAssertEqual(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.latex")), .latex)
    }

    func testHTMLExtensions() {
        XCTAssertEqual(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.html")), .html)
        XCTAssertEqual(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.htm")), .html)
    }

    func testUnknownExtensionReturnsNil() {
        XCTAssertNil(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertNil(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a")))
    }

    func testCaseInsensitivity() {
        XCTAssertEqual(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.MD")), .markdown)
        XCTAssertEqual(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.TeX")), .latex)
        XCTAssertEqual(DocumentFormat.forURL(URL(fileURLWithPath: "/tmp/a.HTML")), .html)
    }

    func testAllCasesAreExhaustive() {
        XCTAssertEqual(DocumentFormat.allCases.count, 3)
        XCTAssertTrue(DocumentFormat.allCases.contains(.markdown))
        XCTAssertTrue(DocumentFormat.allCases.contains(.latex))
        XCTAssertTrue(DocumentFormat.allCases.contains(.html))
    }
}
