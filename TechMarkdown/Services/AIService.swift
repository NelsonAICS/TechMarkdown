import Foundation

/// OpenAI 兼容 API 的封装，支持非流式与 AG-UI 流式事件输出。
final class AIService {
    static let shared = AIService()
    
    func chat(
        messages: [ChatMessage],
        documentText: String,
        referencedFiles: [ReferencedFile],
        selectedTextSnippets: [SelectedTextSnippet] = [],
        tools: [ToolDefinition],
        configuration: AIProviderConfiguration,
        apiKey: String,
        currentFilePath: String? = nil,
        annotations: [Annotation] = []
    ) async throws -> AIChatResponse {
        let body = try makeRequestBody(
            messages: messages,
            documentText: documentText,
            referencedFiles: referencedFiles,
            selectedTextSnippets: selectedTextSnippets,
            tools: tools,
            configuration: configuration,
            stream: false,
            currentFilePath: currentFilePath,
            annotations: annotations
        )
        let data = try await performRequest(body: body, configuration: configuration, apiKey: apiKey)
        return try JSONDecoder().decode(AIChatResponse.self, from: data)
    }
    
    /// 流式对话，将 OpenAI SSE 输出解析为 AG-UI 事件序列
    func chatStream(
        messages: [ChatMessage],
        documentText: String,
        referencedFiles: [ReferencedFile],
        selectedTextSnippets: [SelectedTextSnippet] = [],
        tools: [ToolDefinition],
        configuration: AIProviderConfiguration,
        apiKey: String,
        threadId: String,
        runId: String,
        messageId: String,
        currentFilePath: String? = nil,
        annotations: [Annotation] = []
    ) -> AsyncThrowingStream<AGUIEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let body = try self.makeRequestBody(
                        messages: messages,
                        documentText: documentText,
                        referencedFiles: referencedFiles,
                        selectedTextSnippets: selectedTextSnippets,
                        tools: tools,
                        configuration: configuration,
                        stream: true,
                        currentFilePath: currentFilePath,
                        annotations: annotations
                    )
                    
                    var request = URLRequest(url: URL(string: configuration.baseURL)!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !apiKey.isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = body
                    
                    let (stream, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        var body = Data()
                        for try await byte in stream {
                            body.append(byte)
                        }
                        let errorText = String(data: body, encoding: .utf8) ?? "未知错误"
                        continuation.finish(throwing: NSError(domain: "AIService", code: 1, userInfo: [NSLocalizedDescriptionKey: "请求失败: \(errorText)"]))
                        return
                    }
                    
                    var accumulator = StreamAccumulator()
                    accumulator.messageId = messageId
                    accumulator.runId = runId
                    accumulator.threadId = threadId
                    
                    for try await line in stream.lines {
                        guard !Task.isCancelled else { break }
                        self.parseSSELine(line, accumulator: &accumulator, continuation: continuation)
                    }
                    
                    self.flushPendingToolCall(accumulator: &accumulator, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func parseSSELine(
        _ line: String,
        accumulator: inout StreamAccumulator,
        continuation: AsyncThrowingStream<AGUIEvent, Error>.Continuation
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data: ") else { return }
        let json = String(trimmed.dropFirst(6))
        guard json != "[DONE]" else { return }

        do {
            let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: json.data(using: .utf8)!)
            guard let choice = chunk.choices.first else { return }
            let delta = choice.delta
            let finishReason = choice.finishReason

            // 推理内容
            if let reasoning = delta?.reasoningContent, !reasoning.isEmpty {
                continuation.yield(AGUIEvent(
                    type: .reasoningMessageContent,
                    threadId: accumulator.threadId,
                    runId: accumulator.runId,
                    messageId: accumulator.messageId,
                    payload: ReasoningMessageContentPayload(
                        messageId: accumulator.messageId,
                        delta: reasoning
                    )
                ))
            }

            // 工具调用增量
            if let toolCalls = delta?.toolCalls, !toolCalls.isEmpty {
                for callDelta in toolCalls {
                    let index = callDelta.index ?? accumulator.currentToolCallIndex ?? 0
                    if let currentIndex = accumulator.currentToolCallIndex, index != currentIndex, accumulator.pendingToolCall {
                        emitToolCallEnd(accumulator: &accumulator, continuation: continuation)
                    }
                    accumulator.currentToolCallIndex = index
                    accumulator.pendingToolCall = true

                    let toolCallId = callDelta.id ?? accumulator.currentToolCallId
                    if !toolCallId.isEmpty {
                        accumulator.currentToolCallId = toolCallId
                    }

                    if let name = callDelta.function?.name {
                        accumulator.toolCallName = name
                        accumulator.toolCallIds.append(toolCallId)
                        continuation.yield(AGUIEvent(
                            type: .toolCallStart,
                            threadId: accumulator.threadId,
                            runId: accumulator.runId,
                            messageId: accumulator.messageId,
                            toolCallId: toolCallId,
                            payload: ToolCallStartPayload(
                                toolCallId: toolCallId,
                                toolCallName: name,
                                parentMessageId: accumulator.messageId
                            )
                        ))
                    }

                    if let argsDelta = callDelta.function?.arguments, !argsDelta.isEmpty {
                        continuation.yield(AGUIEvent(
                            type: .toolCallArgs,
                            threadId: accumulator.threadId,
                            runId: accumulator.runId,
                            messageId: accumulator.messageId,
                            toolCallId: toolCallId,
                            payload: ToolCallArgsPayload(
                                toolCallId: toolCallId,
                                delta: argsDelta
                            )
                        ))
                    }
                }
            } else if accumulator.pendingToolCall && (finishReason == "tool_calls" || finishReason == "stop") {
                emitToolCallEnd(accumulator: &accumulator, continuation: continuation)
            }

            // 文本内容
            if let content = delta?.content {
                accumulator.hasStartedText = true
                continuation.yield(AGUIEvent(
                    type: .textMessageContent,
                    threadId: accumulator.threadId,
                    runId: accumulator.runId,
                    messageId: accumulator.messageId,
                    payload: TextMessageContentPayload(
                        messageId: accumulator.messageId,
                        delta: content
                    )
                ))
            }
        } catch {
            // 忽略无法解析的单行
        }
    }

    private func emitToolCallEnd(
        accumulator: inout StreamAccumulator,
        continuation: AsyncThrowingStream<AGUIEvent, Error>.Continuation
    ) {
        let toolCallId = accumulator.currentToolCallId
        guard accumulator.pendingToolCall, !toolCallId.isEmpty else { return }
        continuation.yield(AGUIEvent(
            type: .toolCallEnd,
            threadId: accumulator.threadId,
            runId: accumulator.runId,
            messageId: accumulator.messageId,
            toolCallId: toolCallId,
            payload: ToolCallEndPayload(toolCallId: toolCallId)
        ))
        accumulator.pendingToolCall = false
        accumulator.currentToolCallId = ""
        accumulator.currentToolCallIndex = nil
        accumulator.toolCallName = ""
    }

    private func flushPendingToolCall(
        accumulator: inout StreamAccumulator,
        continuation: AsyncThrowingStream<AGUIEvent, Error>.Continuation
    ) {
        if accumulator.pendingToolCall {
            emitToolCallEnd(accumulator: &accumulator, continuation: continuation)
        }
    }
    
    func makeRequestBody(
        messages: [ChatMessage],
        documentText: String,
        referencedFiles: [ReferencedFile],
        selectedTextSnippets: [SelectedTextSnippet],
        tools: [ToolDefinition],
        configuration: AIProviderConfiguration,
        stream: Bool,
        currentFilePath: String?,
        annotations: [Annotation] = []
    ) throws -> Data {
        var payloadMessages: [[String: Any]] = []
        
        var systemPrompt = configuration.systemPrompt
        let includedReferences = referencedFiles.filter(\.isIncluded)
        let lastUserText = messages.last(where: { $0.role == .user })?.content ?? ""
        let contextResolution = AIContextResolver.resolve(
            userText: lastUserText,
            currentFilePath: currentFilePath,
            referencedFiles: includedReferences
        )
        systemPrompt += """

        <本轮上下文规则>
        \(contextResolution.promptInstruction)
        只依据实际提供的正文回答；无法从资料确认的内容要明确说明。
        输出必须使用结构清晰的标准 Markdown：
        - 标题、段落、列表分别独占行；
        - 块与块之间保留空行；
        - 不要把标题、编号、正文压缩在同一行；
        - 长回答优先使用二级标题和项目列表。
        </本轮上下文规则>
        """

        if !tools.contains(where: { $0.riskLevel == .documentProposal }) {
            systemPrompt += """

            <本轮操作权限>
            本轮是只读任务。请在对话中直接给出总结、简介、提纲、润色稿、译文或分析结果。
            不得声称已经修改文档，也不得尝试调用或伪造任何文档修改工具。
            </本轮操作权限>
            """
        }

        if currentFilePath?.lowercased().hasSuffix(".pdf") == true {
            systemPrompt += """

            <PDF只读规则>
            当前文档是 PDF。可以阅读、总结、问答并结合页码批注分析，但不得调用文档修改工具，
            不得声称已修改 PDF。若用户希望改写内容，只能输出独立建议或草稿。
            </PDF只读规则>
            """
        }

        if !documentText.isEmpty, contextResolution.focus != .referencedFiles {
            systemPrompt += "\n\n<当前编辑文档>\n\(documentText)\n</当前编辑文档>"
        }
        if !includedReferences.isEmpty {
            let fileContext = includedReferences
                .map {
                    """
                    <引用文件 path="\($0.path)">
                    \($0.contentPreview)
                    </引用文件>
                    """
                }
                .joined(separator: "\n---\n")
            systemPrompt += "\n\n<用户主动附加的文件>\n\(fileContext)\n</用户主动附加的文件>"
        }
        if !selectedTextSnippets.isEmpty {
            let snippetsContext = selectedTextSnippets
                .map { "选中片段：\n\($0.content)" }
                .joined(separator: "\n---\n")
            systemPrompt += "\n\n用户在编辑器中选中的文本片段：\n\(snippetsContext)\n\n请基于当前文档内容和上述选中的文本片段回答用户问题或执行修改要求。"
        }
        
        let memory = MemoryService.shared.loadMemory()
        if !memory.isEmpty {
            systemPrompt += "\n\n核心记忆（编辑风格与偏好）：\n\(memory)"
        }
        
        let profileSection = MemoryService.shared.profilePromptSection()
        if !profileSection.isEmpty {
            systemPrompt += "\n\n\(profileSection)"
        }
        
        let recentFilesSection = MemoryService.shared.recentFilesPromptSection(limit: 10)
        if !recentFilesSection.isEmpty {
            systemPrompt += "\n\n\(recentFilesSection)"
        }
        
        let unresolvedAnnotations = annotations.filter { !$0.resolved }
        if !unresolvedAnnotations.isEmpty {
            let annotationContext = unresolvedAnnotations
                .map { annotation in
                    let location = annotation.pdfAnchor.map { "PDF 第 \($0.pageIndex + 1) 页" }
                        ?? annotation.context
                    let selected = annotation.selectedText.isEmpty
                        ? ""
                        : "\n  关联原文：\(annotation.selectedText)"
                    return "- [\(location)] \(annotation.text)\(selected)"
                }
                .joined(separator: "\n")
            systemPrompt += "\n\n当前文档批注（请优先根据这些批注优化内容）：\n\(annotationContext)"
        }
        
        payloadMessages.append(["role": "system", "content": systemPrompt])
        
        let recentMessages = Array(messages.suffix(configuration.maxHistoryTurns * 2))
        for message in recentMessages {
            payloadMessages.append(contentsOf: message.dictionaryRepresentations())
        }
        
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": payloadMessages,
            "stream": stream,
            "temperature": configuration.temperature
        ]
        
        let availableTools = currentFilePath?.lowercased().hasSuffix(".pdf") == true
            ? tools.filter { $0.riskLevel != .documentProposal }
            : tools
        if !availableTools.isEmpty {
            body["tools"] = availableTools.map { $0.openAISchema }
            body["tool_choice"] = "auto"
        }
        
        return try JSONSerialization.data(withJSONObject: body)
    }
    
    private func performRequest(body: Data, configuration: AIProviderConfiguration, apiKey: String) async throws -> Data {
        guard let url = URL(string: configuration.baseURL) else {
            throw NSError(domain: "AIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 端点"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "AIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "AI 请求失败: \(errorText)"])
        }
        return data
    }
}

// MARK: - 非流式响应模型

struct AIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var role: String
            var content: String?
            var toolCalls: [AIChatToolCall]?
            
            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }
        var message: Message
    }
    var choices: [Choice]
    
    var content: String { choices.first?.message.content ?? "" }
}

struct AIChatToolCall: Decodable {
    var id: String
    var function: AIChatFunctionCall
}

struct AIChatFunctionCall: Decodable {
    var name: String
    var arguments: String
}

private struct StreamAccumulator {
    var messageId: String = ""
    var runId: String = ""
    var threadId: String = ""
    var hasStartedText = false
    var currentToolCallId: String = ""
    var currentToolCallIndex: Int?
    var pendingToolCall = false
    var toolCallName: String = ""
    var toolCallIds: [String] = []
}

// MARK: - OpenAI 流式响应模型
private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var role: String?
            var content: String?
            var reasoningContent: String?
            var toolCalls: [ToolCallDelta]?

            enum CodingKeys: String, CodingKey {
                case role, content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }
        var delta: Delta?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    var choices: [Choice]
}

private struct ToolCallDelta: Decodable {
    var index: Int?
    var id: String?
    var type: String?
    var function: FunctionDelta?
}

private struct FunctionDelta: Decodable {
    var name: String?
    var arguments: String?
}
