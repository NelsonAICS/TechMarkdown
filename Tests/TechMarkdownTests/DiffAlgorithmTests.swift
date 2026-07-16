import XCTest
@testable import TechMarkdown

final class DiffAlgorithmTests: XCTestCase {

    func testEmptyTextsReturnNoDiff() {
        let diff = computeLineDiff(oldText: "", newText: "")
        XCTAssertEqual(diff.count, 0)
    }

    func testIdenticalTextsReturnUnchangedLines() {
        let text = "line1\nline2\nline3"
        let diff = computeLineDiff(oldText: text, newText: text)
        XCTAssertEqual(diff.count, 3)
        XCTAssertTrue(diff.allSatisfy { $0.type == .unchanged })
        XCTAssertEqual(diff.map { $0.text }, ["line1", "line2", "line3"])
    }

    func testAddedLine() {
        let diff = computeLineDiff(oldText: "a\nb", newText: "a\nb\nc")
        let types = diff.map { $0.type }
        XCTAssertEqual(types, [.unchanged, .unchanged, .added])
        XCTAssertEqual(diff.last?.text, "c")
        XCTAssertEqual(diff.last?.newLineNumber, 3)
        XCTAssertNil(diff.last?.oldLineNumber)
    }

    func testRemovedLine() {
        let diff = computeLineDiff(oldText: "a\nb\nc", newText: "a\nc")
        let types = diff.map { $0.type }
        XCTAssertEqual(types, [.unchanged, .removed, .unchanged])
        let removed = diff.first { $0.type == .removed }
        XCTAssertEqual(removed?.text, "b")
        XCTAssertEqual(removed?.oldLineNumber, 2)
        XCTAssertNil(removed?.newLineNumber)
    }

    func testReplacedLine() {
        let diff = computeLineDiff(oldText: "hello\nworld", newText: "hello\nswift")
        let types = diff.map { $0.type }
        XCTAssertEqual(types, [.unchanged, .removed, .added])
        XCTAssertEqual(diff.first { $0.type == .added }?.text, "swift")
        XCTAssertEqual(diff.first { $0.type == .removed }?.text, "world")
    }

    func testLineNumbersAreSequential() {
        let diff = computeLineDiff(oldText: "a\nb\nc", newText: "a\nx\nc\nd")
        let unchanged = diff.filter { $0.type == .unchanged }
        let added = diff.filter { $0.type == .added }
        let removed = diff.filter { $0.type == .removed }

        XCTAssertEqual(unchanged.map { $0.oldLineNumber }, [1, 3])
        XCTAssertEqual(unchanged.map { $0.newLineNumber }, [1, 3])
        XCTAssertEqual(removed.map { $0.oldLineNumber }, [2])
        XCTAssertEqual(added.map { $0.newLineNumber }, [2, 4])
    }

    func testWhitespaceMatters() {
        let diff = computeLineDiff(oldText: "a", newText: "a ")
        XCTAssertEqual(diff.count, 2)
        XCTAssertEqual(diff.first { $0.type == .added }?.text, "a ")
        XCTAssertEqual(diff.first { $0.type == .removed }?.text, "a")
    }
}
