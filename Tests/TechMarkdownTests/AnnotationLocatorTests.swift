import XCTest
@testable import TechMarkdown

final class AnnotationLocatorTests: XCTestCase {
    func testPDFAnchorSurvivesCodableRoundTrip() throws {
        let annotation = Annotation(
            text: "检查证据链",
            selectedText: "实验结果",
            context: "PDF 第 3 页",
            pdfAnchor: PDFAnnotationAnchor(
                pageIndex: 2,
                bounds: [CGRect(x: 10, y: 20, width: 120, height: 18)]
            )
        )

        let data = try JSONEncoder().encode(annotation)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)

        XCTAssertEqual(decoded.pdfAnchor, annotation.pdfAnchor)
        XCTAssertEqual(decoded.pdfAnchor?.pageIndex, 2)
    }
    func testExactSnapshotMatchUsesUTF16Range() {
        let annotation = Annotation(
            text: "需要解释",
            selectedText: "beta",
            context: "alpha beta gamma",
            rangeSnapshot: AnnotationRangeSnapshot(
                startLine: 1,
                startColumn: 7,
                endLine: 1,
                endColumn: 10
            )
        )

        let match = AnnotationLocator.locate(annotation, in: "alpha beta gamma")

        XCTAssertEqual(match?.range, NSRange(location: 6, length: 4))
        XCTAssertEqual(match?.quality, .exact)
    }

    func testRelocatesToNearestOccurrenceAfterTextInsertion() {
        let annotation = Annotation(
            text: "检查术语",
            selectedText: "目标",
            context: "前文 目标 后文",
            rangeSnapshot: AnnotationRangeSnapshot(
                startLine: 1,
                startColumn: 4,
                endLine: 1,
                endColumn: 5
            )
        )

        let updated = "新增内容 前文 目标 后文"
        let match = AnnotationLocator.locate(annotation, in: updated)

        XCTAssertEqual(match?.range, (updated as NSString).range(of: "目标"))
        XCTAssertEqual(match?.quality, .relocated)
    }

    func testContextDisambiguatesRepeatedTextWithoutSnapshot() {
        let annotation = Annotation(
            text: "修改第二处",
            selectedText: "重复",
            context: "第二段包含重复文本"
        )
        let text = "第一段包含重复文本\n第二段包含重复文本"

        let match = AnnotationLocator.locate(annotation, in: text)
        let expectedContext = (text as NSString).range(of: "第二段包含重复文本")
        let expected = (text as NSString).range(
            of: "重复",
            options: [],
            range: expectedContext
        )

        XCTAssertEqual(match?.range, expected)
        XCTAssertEqual(match?.quality, .approximate)
    }

    func testReturnsNilWhenAnchoredTextNoLongerExists() {
        let annotation = Annotation(
            text: "已失效",
            selectedText: "被删除的文本",
            context: "旧上下文"
        )

        XCTAssertNil(AnnotationLocator.locate(annotation, in: "全新的正文"))
    }
}
