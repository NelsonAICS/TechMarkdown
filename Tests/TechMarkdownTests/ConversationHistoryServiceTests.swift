import XCTest
@testable import TechMarkdown

final class ConversationHistoryServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: ConversationHistoryService!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TechMarkdownStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        store = try ConversationHistoryService(
            databaseURL: temporaryDirectory.appendingPathComponent("Workspace.sqlite")
        )
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testConversationRoundTripPreservesFileContext() throws {
        let file = ReferencedFile(
            id: UUID(),
            path: "/tmp/reference.md",
            contentPreview: "reference",
            isIncluded: true
        )
        let conversation = Conversation(
            title: "研究对话",
            messages: [ChatMessage(role: .user, content: "分析文档")],
            threadID: "thread-stable",
            context: ConversationContext(
                primaryFilePath: "/tmp/project/paper.md",
                referencedFiles: [file],
                documentFingerprint: ContentFingerprint.make("paper")
            )
        )

        store.save(conversation)
        let loaded = try XCTUnwrap(store.load(id: conversation.id))

        XCTAssertEqual(loaded.threadID, "thread-stable")
        XCTAssertEqual(loaded.context.referencedFiles, [file])
        XCTAssertEqual(loaded.context.documentFingerprint, ContentFingerprint.make("paper"))
    }

    func testStartingNewConversationPreservesCurrentHistoryAndResetsRuntimeState() throws {
        let agent = AIAgent(historyService: store)
        let conversationID = UUID()
        let previousThreadID = agent.threadId
        agent.currentConversationId = conversationID
        agent.currentFilePath = "/tmp/project/paper.md"
        agent.messages = [ChatMessage(role: .user, content: "继续分析第三节")]
        agent.currentStreamingContent = "尚未完成的流式内容"
        agent.currentStreamingReasoning = "临时推理"
        agent.currentToolCallName = "search_project"

        agent.startNewConversation(documentText: "# 论文正文")

        let stored = try XCTUnwrap(store.load(id: conversationID))
        XCTAssertEqual(stored.messages.map(\.content), ["继续分析第三节"])
        XCTAssertEqual(stored.context.primaryFilePath, "/tmp/project/paper.md")
        XCTAssertTrue(agent.messages.isEmpty)
        XCTAssertNil(agent.currentConversationId)
        XCTAssertNotEqual(agent.threadId, previousThreadID)
        XCTAssertEqual(agent.currentStreamingContent, "")
        XCTAssertEqual(agent.currentStreamingReasoning, "")
        XCTAssertNil(agent.currentToolCallName)
        XCTAssertEqual(agent.state, .idle)
    }

    func testListsConversationsForCurrentFileOnly() {
        let first = Conversation(
            title: "A",
            context: ConversationContext(primaryFilePath: "/tmp/project/a.md")
        )
        let second = Conversation(
            title: "B",
            context: ConversationContext(primaryFilePath: "/tmp/project/b.md")
        )
        store.save(first)
        store.save(second)

        XCTAssertEqual(store.list(forFilePath: "/tmp/project/a.md").map(\.id), [first.id])
    }

    func testRunAndStepsPersistInOrder() throws {
        let conversation = Conversation(title: "运行记录")
        store.save(conversation)
        let run = AgentRunRecord(
            conversationID: conversation.id,
            threadID: conversation.threadID,
            checkpointMessageCount: 1
        )
        store.saveRun(run)
        store.saveStep(
            AgentRunStep(
                runID: run.id,
                sequence: 1,
                kind: .generation,
                status: .completed,
                title: "生成"
            )
        )
        store.saveStep(
            AgentRunStep(
                runID: run.id,
                sequence: 0,
                kind: .context,
                status: .completed,
                title: "上下文"
            )
        )

        let loadedRun = try XCTUnwrap(store.loadRuns(conversationID: conversation.id).first)
        XCTAssertEqual(loadedRun.id, run.id)
        XCTAssertEqual(loadedRun.status, run.status)
        XCTAssertEqual(loadedRun.checkpointMessageCount, run.checkpointMessageCount)
        XCTAssertEqual(store.loadSteps(runID: run.id).map(\.sequence), [0, 1])
    }

    func testStartupMarksActiveRunInterruptedButKeepsApprovalWaiting() throws {
        let conversation = Conversation(title: "恢复")
        store.save(conversation)
        var generating = AgentRunRecord(
            conversationID: conversation.id,
            threadID: conversation.threadID,
            status: .generating,
            checkpointMessageCount: 1
        )
        var waiting = AgentRunRecord(
            conversationID: conversation.id,
            threadID: conversation.threadID,
            status: .awaitingApproval,
            checkpointMessageCount: 1
        )
        store.saveRun(generating)
        store.saveRun(waiting)

        try store.markActiveRunsInterrupted()
        let runs = store.loadRuns(conversationID: conversation.id)
        generating.transition(to: .interrupted, error: "应用退出前运行未完成", at: runs[0].updatedAt)
        waiting.updatedAt = runs[1].updatedAt

        XCTAssertEqual(runs[0].status, .interrupted)
        XCTAssertEqual(runs[1].status, .awaitingApproval)
    }

    func testAppliedEditReceiptIsIdempotent() {
        let editID = UUID()
        XCTAssertTrue(
            store.recordAppliedEdit(
                editID: editID,
                conversationID: nil,
                runID: nil,
                filePath: "/tmp/paper.md",
                resultFingerprint: "first"
            )
        )
        XCTAssertFalse(
            store.recordAppliedEdit(
                editID: editID,
                conversationID: nil,
                runID: nil,
                filePath: "/tmp/paper.md",
                resultFingerprint: "second"
            )
        )
        XCTAssertTrue(store.hasAppliedEdit(editID))
    }

    func testDeletingConversationCascadesRunsAndSteps() {
        let conversation = Conversation(title: "删除")
        store.save(conversation)
        let run = AgentRunRecord(
            conversationID: conversation.id,
            threadID: conversation.threadID,
            checkpointMessageCount: 0
        )
        store.saveRun(run)
        store.saveStep(
            AgentRunStep(
                runID: run.id,
                sequence: 0,
                kind: .context,
                title: "上下文"
            )
        )

        store.delete(id: conversation.id)

        XCTAssertNil(store.load(id: conversation.id))
        XCTAssertTrue(store.loadRuns(conversationID: conversation.id).isEmpty)
        XCTAssertTrue(store.loadSteps(runID: run.id).isEmpty)
    }

    func testReopeningDatabaseRestoresConversationAndConvertsActiveRunToRecoverable() throws {
        let edit = PendingEdit(
            originalText: "旧正文",
            suggestedText: "新正文",
            reason: "改善表达",
            hunks: DiffService.computeHunks(original: "旧正文", suggested: "新正文")
        )
        let conversation = Conversation(
            title: "可续接对话",
            messages: [ChatMessage(role: .user, content: "继续修改这份文档")],
            context: ConversationContext(
                primaryFilePath: "/tmp/project/paper.md",
                documentFingerprint: ContentFingerprint.make("旧正文"),
                pendingEdit: edit
            )
        )
        store.save(conversation)
        let run = AgentRunRecord(
            conversationID: conversation.id,
            threadID: conversation.threadID,
            status: .generating,
            checkpointMessageCount: 1
        )
        store.saveRun(run)

        let databaseURL = temporaryDirectory.appendingPathComponent("Workspace.sqlite")
        store = nil
        store = try ConversationHistoryService(databaseURL: databaseURL)

        let restored = try XCTUnwrap(store.load(id: conversation.id))
        XCTAssertEqual(restored.context.pendingEdit?.id, edit.id)
        XCTAssertEqual(restored.context.primaryFilePath, "/tmp/project/paper.md")
        XCTAssertEqual(store.loadRuns(conversationID: conversation.id).last?.status, .interrupted)
    }
}
