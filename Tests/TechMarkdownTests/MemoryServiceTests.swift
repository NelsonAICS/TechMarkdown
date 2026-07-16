import XCTest
@testable import TechMarkdown

final class MemoryServiceTests: XCTestCase {

    private var tempDirectory: URL!
    private var service: MemoryService!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        service = MemoryService(directoryURL: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        service = nil
        super.tearDown()
    }

    func testLoadMemoryReturnsDefaultTemplateWhenEmpty() {
        let memory = service.loadMemory()
        XCTAssertTrue(memory.contains("AI 核心记忆"))
        XCTAssertTrue(memory.contains("编辑偏好"))
    }

    func testSaveAndLoadMemory() {
        let text = "# 我的记忆\n\n- 偏好 Swift"
        service.saveMemory(text)
        let loaded = service.loadMemory()
        XCTAssertEqual(loaded, text)
    }

    func testRecordFileInteractionCreatesEntry() {
        let expectation = XCTestExpectation(description: "File index persisted")
        service.recordFileInteraction(path: "/tmp/test-note.md", text: "# Hello\n\nWorld content here.")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            let entries = self.service.recentFileIndexEntries(limit: 10)
            DispatchQueue.main.async {
                XCTAssertEqual(entries.count, 1)
                XCTAssertEqual(entries.first?.title, "Hello")
                XCTAssertEqual(entries.first?.path, "/tmp/test-note.md")
                XCTAssertEqual(entries.first?.wordCount, 4)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testRecentFilesAreSortedByLastOpened() {
        let expectation = XCTestExpectation(description: "Recent files sorted")
        service.recordFileInteraction(path: "/tmp/oldest.md", text: "Oldest")
        service.recordFileInteraction(path: "/tmp/newest.md", text: "Newest")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            // 更新 oldest 的打开时间使其排到 newest 后面
            self.service.recordFileInteraction(path: "/tmp/oldest.md", text: "Oldest updated")

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                let entries = self.service.recentFileIndexEntries(limit: 10)
                DispatchQueue.main.async {
                    XCTAssertEqual(entries.count, 2)
                    XCTAssertEqual(entries.first?.path, "/tmp/oldest.md")
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 3.0)
    }

    func testSearchFileIndexFiltersByTitle() {
        let expectation = XCTestExpectation(description: "Search by title")
        service.recordFileInteraction(path: "/tmp/swift-guide.md", text: "# Swift Guide")
        service.recordFileInteraction(path: "/tmp/python-guide.md", text: "# Python Guide")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            let results = self.service.searchFileIndex(query: "swift")
            DispatchQueue.main.async {
                XCTAssertEqual(results.count, 1)
                XCTAssertEqual(results.first?.title, "Swift Guide")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testDirectoryURLIsInjected() {
        XCTAssertEqual(service.directoryURL, tempDirectory)
    }

    func testClearFileIndexRemovesAllEntries() {
        let expectation = XCTestExpectation(description: "File index cleared")
        service.recordFileInteraction(path: "/tmp/note-a.md", text: "# A")
        service.recordFileInteraction(path: "/tmp/note-b.md", text: "# B")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.service.clearFileIndex()

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                let entries = self.service.recentFileIndexEntries(limit: 10)
                DispatchQueue.main.async {
                    XCTAssertEqual(entries.count, 0)
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 3.0)
    }
}
