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
    
    private func makeRequestBody(
        messages: [ChatMessage],
        documentText: String,
        referencedFiles: [ReferencedFile],
        selectedTextSnippets: [SelectedTextSnippet],
        tools: [ToolDefinition],
        configuration: AIProviderConfiguration,
        stream: Bool,
        annotations: [Annotation] = []
    ) throws -> Data {
        var payloadMessages: [[String: Any]] = []
        
        var systemPrompt = configuration.systemPrompt
        if !documentText.isEmpty {
            systemPrompt += "\n\n当前文档内容：\n\(documentText)"
        }
        if !referencedFiles.isEmpty {
            let fileContext = referencedFiles
                .filter { $0.isIncluded }
                .map { "文件: \($0.path)\n\($0.contentPreview)" }
                .joined(separator: "\n---\n")
            systemPrompt += "\n\n引用文件内容：\n\(fileContext)"
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
                .map { "- [\($0.createdAt.formatted())] \($0.text)" }
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
        
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.openAISchema }
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
