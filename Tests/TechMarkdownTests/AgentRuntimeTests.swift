import XCTest
@testable import TechMarkdown

final class AgentRuntimeTests: XCTestCase {
    func testTerminalAndRecoverableRunStates() {
        XCTAssertTrue(AgentRunStatus.completed.isTerminal)
        XCTAssertTrue(AgentRunStatus.failed.isTerminal)
        XCTAssertTrue(AgentRunStatus.interrupted.isRecoverable)
        XCTAssertTrue(AgentRunStatus.failed.isRecoverable)
        XCTAssertFalse(AgentRunStatus.cancelled.isRecoverable)
        XCTAssertFalse(AgentRunStatus.generating.isTerminal)
    }

    func testStepExpansionDefaultsKeepAttentionStatesOpen() {
        let runID = UUID()
        let running = AgentRunStep(
            runID: runID,
            sequence: 0,
            kind: .generation,
            status: .running,
            title: "生成回答"
        )
        let failed = AgentRunStep(
            runID: runID,
            sequence: 1,
            kind: .error,
            status: .failed,
            title: "请求失败"
        )
        let completed = AgentRunStep(
            runID: runID,
            sequence: 2,
            kind: .context,
            status: .completed,
            title: "上下文就绪"
        )

        XCTAssertTrue(running.isExpandedByDefault)
        XCTAssertTrue(failed.isExpandedByDefault)
        XCTAssertFalse(completed.isExpandedByDefault)
    }

    func testContentFingerprintIsStableAndSensitiveToChanges() {
        XCTAssertEqual(ContentFingerprint.make("same"), ContentFingerprint.make("same"))
        XCTAssertNotEqual(ContentFingerprint.make("same"), ContentFingerprint.make("changed"))
    }

    func testLegacyConversationJSONDecodesWithDurableDefaults() throws {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let legacy = Conversation(
            id: id,
            title: "旧对话",
            createdAt: createdAt,
            updatedAt: createdAt,
            messages: [ChatMessage(role: .user, content: "你好")]
        )
        let encoded = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "threadID")
        object.removeValue(forKey: "context")
        object.removeValue(forKey: "isPinned")
        object.removeValue(forKey: "isArchived")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Conversation.self, from: legacyData)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.threadID, id.uuidString)
        XCTAssertNil(decoded.context.primaryFilePath)
        XCTAssertFalse(decoded.isPinned)
    }

    func testPendingEditRoundTripsWithStableIdentity() throws {
        let edit = PendingEdit(
            originalText: "old",
            suggestedText: "new",
            reason: "改进表达",
            hunks: [EditHunk(oldStart: 1, oldLines: ["old"], newLines: ["new"])]
        )

        let data = try JSONEncoder().encode(edit)
        let decoded = try JSONDecoder().decode(PendingEdit.self, from: data)

        XCTAssertEqual(decoded.id, edit.id)
        XCTAssertEqual(decoded.hunks.first?.id, edit.hunks.first?.id)
    }

    func testRuntimePolicyBoundsAgentLoop() {
        XCTAssertEqual(AgentRuntimePolicy.maximumModelRounds, 8)
        XCTAssertEqual(AgentRuntimePolicy.maximumToolCalls, 12)
    }

    func testDocumentEditToolsAreClassifiedAsProposals() {
        let definition = ToolDefinition(
            name: "apply_markdown_edit",
            description: "edit",
            parameters: [],
            requiredParameters: []
        )
        XCTAssertEqual(definition.riskLevel, .documentProposal)
    }

    func testRecoveryOnlyReturnsToolCallsWithoutReceipts() {
        let completed = ToolCall(
            id: "call-complete",
            function: ToolCallFunction(name: "read_file", arguments: "{}")
        )
        let unresolved = ToolCall(
            id: "call-pending",
            function: ToolCallFunction(name: "search_project", arguments: "{}")
        )
        let messages = [
            ChatMessage(role: .assistant, content: "", toolCalls: [completed, unresolved]),
            ChatMessage(role: .tool, content: "done", toolCallID: completed.id)
        ]

        XCTAssertEqual(
            AgentRecoveryPlanner.unresolvedToolCalls(in: messages).map(\.id),
            [unresolved.id]
        )
    }

    func testLegacyDocumentVersionDecodesWithoutAgentMetadata() throws {
        let legacyObject: [String: Any] = [
            "id": UUID().uuidString,
            "timestamp": Date(timeIntervalSince1970: 100).timeIntervalSinceReferenceDate,
            "text": "正文",
            "reason": "保存",
            "isAutoSave": false
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate

        let version = try decoder.decode(DocumentVersion.self, from: data)
        XCTAssertNil(version.filePath)
        XCTAssertNil(version.editID)
    }

    func testAttachedFileBecomesPrimaryTargetForAmbiguousRequest() {
        let reference = ReferencedFile(
            id: UUID(),
            path: "/project/08-技术亮点速查卡.md",
            contentPreview: "附件正文",
            isIncluded: true
        )

        let resolution = AIContextResolver.resolve(
            userText: "帮我总结一下这个文档",
            currentFilePath: "/project/00-阅读指南.md",
            referencedFiles: [reference]
        )

        XCTAssertEqual(resolution.focus, .referencedFiles)
        XCTAssertEqual(resolution.primarySourceNames, ["08-技术亮点速查卡.md"])
        XCTAssertTrue(resolution.promptInstruction.contains("不要把当前编辑文档当作本轮总结对象"))
    }

    func testContextTargetCanExplicitlySelectCurrentOrCombinedDocuments() {
        let reference = ReferencedFile(
            id: UUID(),
            path: "/project/reference.md",
            contentPreview: "附件",
            isIncluded: true
        )

        XCTAssertEqual(
            AIContextResolver.resolve(
                userText: "总结当前文档",
                currentFilePath: "/project/current.md",
                referencedFiles: [reference]
            ).focus,
            .currentDocument
        )
        XCTAssertEqual(
            AIContextResolver.resolve(
                userText: "结合当前文档和这些文件一起分析",
                currentFilePath: "/project/current.md",
                referencedFiles: [reference]
            ).focus,
            .combined
        )
    }
}
