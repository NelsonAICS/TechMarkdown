import XCTest
@testable import TechMarkdown

final class IntentRecognitionTests: XCTestCase {
    private let service = IntentRecognitionService.shared
    private let document = "# 示例文档\n\n这里是正文。"

    func testAmbiguousOrganizeRequestDefaultsToConversation() throws {
        let result = try XCTUnwrap(
            service.heuristicClassify("帮我整理一下这篇文档", documentText: document)
        )

        XCTAssertEqual(result.goal, .organize)
        XCTAssertEqual(result.intent, .chat)
        XCTAssertEqual(result.output, .conversation)
        XCTAssertEqual(result.mutationPolicy, .readOnly)
        XCTAssertFalse(result.allowsDocumentProposal)
        XCTAssertFalse(result.preferredTools.contains("apply_markdown_edit"))
    }

    func testSummaryWithExplicitOutputRemainsReadOnly() throws {
        let result = try XCTUnwrap(
            service.heuristicClassify(
                "整理文档，给我输出一段内容简介，不要修改原文",
                documentText: document
            )
        )

        XCTAssertEqual(result.goal, .summarize)
        XCTAssertEqual(result.output, .conversation)
        XCTAssertEqual(result.mutationPolicy, .readOnly)
        XCTAssertTrue(result.evidence.contains("不要修改"))
    }

    func testPolishWithoutWriteBackSignalReturnsDraftInChat() throws {
        let result = try XCTUnwrap(
            service.heuristicClassify("帮我润色当前文档，先给我看看", documentText: document)
        )

        XCTAssertEqual(result.goal, .rewrite)
        XCTAssertEqual(result.intent, .chat)
        XCTAssertEqual(result.output, .conversation)
        XCTAssertFalse(result.allowsDocumentProposal)
    }

    func testExplicitWriteBackEnablesEditProposal() throws {
        let result = try XCTUnwrap(
            service.heuristicClassify(
                "把这篇文档整理得更有条理并替换正文",
                documentText: document
            )
        )

        XCTAssertEqual(result.goal, .organize)
        XCTAssertEqual(result.intent, .editDocument)
        XCTAssertEqual(result.output, .documentEditProposal)
        XCTAssertEqual(result.mutationPolicy, .proposeDocumentEdit)
        XCTAssertTrue(result.allowsDocumentProposal)
        XCTAssertTrue(result.preferredTools.contains("apply_markdown_edit"))
    }

    func testReadOnlySignalOverridesWriteSignal() throws {
        let result = try XCTUnwrap(
            service.heuristicClassify(
                "先不要修改，整理后给我看看，再决定是否应用到文档",
                documentText: document
            )
        )

        XCTAssertEqual(result.intent, .chat)
        XCTAssertEqual(result.mutationPolicy, .readOnly)
        XCTAssertFalse(result.allowsDocumentProposal)
    }

    func testToolPolicyRemovesDocumentProposalToolsForReadOnlyRun() {
        let tools = [
            tool("apply_markdown_edit"),
            tool("apply_text_edit"),
            tool("search_in_document")
        ]

        let resolved = AgentToolPolicy.resolve(
            tools,
            preferredTools: ["apply_markdown_edit"],
            restrictTools: false,
            allowsDocumentProposal: false
        )

        XCTAssertEqual(resolved.map(\.name), ["search_in_document"])
    }

    func testRestrictedSkillWithNoToolsReceivesNoTools() {
        let tools = [tool("search_in_document"), tool("apply_markdown_edit")]

        let resolved = AgentToolPolicy.resolve(
            tools,
            preferredTools: [],
            restrictTools: true,
            allowsDocumentProposal: false
        )

        XCTAssertTrue(resolved.isEmpty)
    }

    private func tool(_ name: String) -> ToolDefinition {
        ToolDefinition(name: name, description: name, parameters: [], requiredParameters: [])
    }
}
