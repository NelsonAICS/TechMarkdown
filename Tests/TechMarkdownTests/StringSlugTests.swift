import XCTest
@testable import TechMarkdown

final class StringSlugTests: XCTestCase {

    func testEnglishHeadingSlug() {
        XCTAssertEqual("Hello World".markdownHeadingSlug(), "hello-world")
    }

    func testChineseHeadingSlug() {
        XCTAssertEqual("Swift 并发编程".markdownHeadingSlug(), "swift-并发编程")
    }

    func testMixedHeadingSlug() {
        XCTAssertEqual("第 1 章：入门指南".markdownHeadingSlug(), "第-1-章-入门指南")
    }

    func testRemovesPunctuationAndExtraDashes() {
        XCTAssertEqual("A -- B!!  C".markdownHeadingSlug(), "a-b-c")
    }

    func testDiacriticsAreStripped() {
        XCTAssertEqual("Café Résumé".markdownHeadingSlug(), "cafe-resume")
    }

    func testLeadingAndTrailingDashesTrimmed() {
        XCTAssertEqual("-- Hello World --".markdownHeadingSlug(), "hello-world")
    }

    func testNumbersPreserved() {
        XCTAssertEqual("Chapter 42: The Answer".markdownHeadingSlug(), "chapter-42-the-answer")
    }

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual("".markdownHeadingSlug(), "")
    }
}
