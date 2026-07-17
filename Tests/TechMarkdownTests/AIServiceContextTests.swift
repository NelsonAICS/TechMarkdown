import XCTest
@testable import TechMarkdown

final class AIServiceContextTests: XCTestCase {
    func testRequestUsesAttachedFileAsPrimaryAndOmitsDistractingCurrentBody() throws {
        let reference = ReferencedFile(
            id: UUID(),
            path: "/project/08-技术亮点速查卡.md",
            contentPreview: "ATTACHED_FILE_SENTINEL",
            isIncluded: true
        )
        let data = try AIService.shared.makeRequestBody(
            messages: [ChatMessage(role: .user, content: "帮我总结一下这个文档")],
            documentText: "CURRENT_DOCUMENT_SENTINEL",
            referencedFiles: [reference],
            selectedTextSnippets: [],
            tools: [],
            configuration: AIProviderConfiguration(),
            stream: false,
            currentFilePath: "/project/00-阅读指南.md"
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertTrue(systemPrompt.contains("ATTACHED_FILE_SENTINEL"))
        XCTAssertTrue(systemPrompt.contains("08-技术亮点速查卡.md"))
        XCTAssertTrue(systemPrompt.contains("不要把当前编辑文档当作本轮总结对象"))
        XCTAssertFalse(systemPrompt.contains("CURRENT_DOCUMENT_SENTINEL"))
    }

    func testRequestKeepsBothBodiesForCombinedAnalysis() throws {
        let reference = ReferencedFile(
            id: UUID(),
            path: "/project/reference.md",
            contentPreview: "REFERENCE_BODY",
            isIncluded: true
        )
        let data = try AIService.shared.makeRequestBody(
            messages: [ChatMessage(role: .user, content: "结合当前文档和这些文件一起分析")],
            documentText: "CURRENT_BODY",
            referencedFiles: [reference],
            selectedTextSnippets: [],
            tools: [],
            configuration: AIProviderConfiguration(),
            stream: false,
            currentFilePath: "/project/current.md"
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertTrue(systemPrompt.contains("CURRENT_BODY"))
        XCTAssertTrue(systemPrompt.contains("REFERENCE_BODY"))
    }

    func testPDFContextRemovesDocumentMutationTools() throws {
        let tools = [
            ToolDefinition(
                name: "apply_text_edit",
                description: "修改文档",
                parameters: [],
                requiredParameters: []
            ),
            ToolDefinition(
                name: "web_search",
                description: "搜索资料",
                parameters: [],
                requiredParameters: []
            )
        ]
        let data = try AIService.shared.makeRequestBody(
            messages: [ChatMessage(role: .user, content: "总结这份 PDF")],
            documentText: "PDF_TEXT",
            referencedFiles: [],
            selectedTextSnippets: [],
            tools: tools,
            configuration: AIProviderConfiguration(),
            stream: false,
            currentFilePath: "/project/paper.pdf"
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schemas = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let names = schemas.compactMap { schema in
            (schema["function"] as? [String: Any])?["name"] as? String
        }
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertEqual(names, ["web_search"])
        XCTAssertTrue(systemPrompt.contains("PDF只读规则"))
    }
}
