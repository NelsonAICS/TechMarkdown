import XCTest
@testable import TechMarkdown

final class MarkdownMessageParserTests: XCTestCase {
    func testParsesBlockMarkdownIntoIndependentVisualBlocks() {
        let markdown = """
        ## 结论

        这是包含 **重点** 的段落。

        - 第一项
        - 第二项

        1. 步骤一
        2. 步骤二

        > 分析对象：附件.md

        ```swift
        let answer = 42
        ```
        """

        let blocks = MarkdownMessageParser.parse(markdown)

        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0], .heading(level: 2, text: "结论"))
        XCTAssertEqual(
            blocks[2],
            .unorderedList([
                MarkdownListItem(marker: "•", content: "第一项"),
                MarkdownListItem(marker: "•", content: "第二项")
            ])
        )
        XCTAssertEqual(
            blocks[5],
            .code(language: "swift", content: "let answer = 42")
        )
    }

    func testRepairsCommonSingleLineChineseSectionOutput() {
        let source = "文档入口说明—— 一、文档构成内容说明—— 二、阅读路径建议"
        let blocks = MarkdownMessageParser.parse(source)

        XCTAssertEqual(
            blocks.filter {
                if case .heading = $0 { return true }
                return false
            }.count,
            2
        )
    }

    func testParsesMarkdownTable() {
        let markdown = """
        | 文件 | 结论 |
        | --- | --- |
        | A.md | 推荐 |
        """

        XCTAssertEqual(
            MarkdownMessageParser.parse(markdown),
            [.table([["文件", "结论"], ["A.md", "推荐"]])]
        )
    }
}
