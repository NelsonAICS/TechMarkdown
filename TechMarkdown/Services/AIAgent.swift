import Foundation
import SwiftUI
import Combine

/// Agent 运行时状态机
enum AgentState: Equatable {
    case idle
    case streaming
    case executingTools
    case waitingForUserConfirmation
    case finished
    case error(String)
    
    var isActive: Bool {
        switch self {
        case .idle, .finished, .error:
            return false
        case .streaming, .executingTools, .waitingForUserConfirmation:
            return true
        }
    }
    
    var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .streaming: return "生成回复中"
        case .executingTools: return "执行工具中"
        case .waitingForUserConfirmation: return "等待用户确认"
        case .finished: return "完成"
        case .error(let msg): return "错误: \(msg)"
        }
    }
}

/// AIAgent 负责协调对话、工具调用、Skill 执行与文档上下文
/// 同时作为 AG-UI 协议的生产者，将 Agent 内部状态以标准化事件流的形式暴露给 UI。
@Observable
final class AIAgent {
    var messages: [ChatMessage] = []
    var state: AgentState = .idle
    var isProcessing: Bool { state.isActive }
    var errorMessage: String?
    var pendingEdit: PendingEdit?
    var referencedFiles: [ReferencedFile] = []
    var selectedTextSnippets: [SelectedTextSnippet] = []
    var eventBus = AGUIEventBus()
    var currentStreamingContent: String = ""
    var currentStreamingReasoning: String = ""
    var currentToolCallName: String? = nil
    var connectionStatus: String = "未检测"
    var currentConversationId: UUID? = nil
    var lastIntentClassification: IntentClassification? = nil
    var currentFilePath: String? = nil
    
    let threadId: String
    private(set) var configuration: AIProviderConfiguration
    private var apiKey: String
    private let mcpManager = MCPManager.shared
    private var currentRunTask: Task<Void, Never>?
    
    init(configuration: AIProviderConfiguration = AIProviderConfiguration(), apiKey: String = "") {
        self.configuration = configuration
        self.apiKey = apiKey
        self.threadId = UUID().uuidString
        observePendingEditNotification()
        observePendingTextEditNotification()
        observeAddProjectFileToContextNotification()
    }
    
    private func observePendingEditNotification() {
        NotificationCenter.default.addObserver(
            forName: .pendingMarkdownEdit,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let markdown = notification.userInfo?["markdown"] as? String,
                  let reason = notification.userInfo?["reason"] as? String else { return }
            
            self.createPendingEdit(suggestedText: markdown, reason: reason)
        }
    }
    
    private func observePendingTextEditNotification() {
        NotificationCenter.default.addObserver(
            forName: .pendingTextEdit,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let text = notification.userInfo?["text"] as? String,
                  let reason = notification.userInfo?["reason"] as? String else { return }
            
            self.createPendingEdit(suggestedText: text, reason: reason)
        }
    }
    
    private func createPendingEdit(suggestedText: String, reason: String) {
        let currentText = UserDefaults.standard.string(forKey: "techmarkdown.currentDocumentText") ?? ""
        let hunks = DiffService.computeHunks(original: currentText, suggested: suggestedText)
        self.pendingEdit = PendingEdit(
            originalText: currentText,
            suggestedText: suggestedText,
            reason: reason,
            hunks: hunks
        )
        self.state = .waitingForUserConfirmation
        
        self.eventBus.emit(
            .custom,
            messageId: UUID().uuidString,
            payload: CustomPayload(
                name: "PENDING_EDIT_CREATED",
                value: reason
            )
        )
        
        self.eventBus.emit(
            .stateDelta,
            payload: StateDeltaPayload(patch: [
                StatePatchOperation(op: "add", path: "/pendingEdit", value: reason)
            ])
        )
    }
    
    private func observeAddProjectFileToContextNotification() {
        NotificationCenter.default.addObserver(
            forName: .addProjectFileToContext,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let path = notification.userInfo?["path"] as? String else { return }
            Task {
                await self.addProjectFileToContext(path: path)
            }
        }
    }
    
    func updateConfiguration(_ config: AIProviderConfiguration, apiKey: String) {
        self.configuration = config
        self.apiKey = apiKey
    }
    
    /// 后台检测当前 API 配置是否可用，结果写入 connectionStatus
    func checkConnection() {
        let canSkipKey = configuration.providerID == .tokenAPIGate
        guard !apiKey.isEmpty || canSkipKey else {
            connectionStatus = "未配置 API Key"
            return
        }
        connectionStatus = "检测中..."
        Task {
            do {
                let response = try await AIService.shared.chat(
                    messages: [ChatMessage(role: .user, content: "请只回复 OK，测试连接。")],
                    documentText: "",
                    referencedFiles: [],
                    selectedTextSnippets: [],
                    tools: [],
                    configuration: configuration,
                    apiKey: apiKey
                )
                await MainActor.run {
                    let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    connectionStatus = trimmed.isEmpty
                        ? "连接成功，但模型返回为空"
                        : "连接成功: \(trimmed.prefix(30))"
                }
            } catch {
                await MainActor.run {
                    connectionStatus = "连接失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func addReferencedFile(path: String) async {
        do {
            let content = try await FileContextService.shared.readFile(at: path, maxLength: 50_000)
            let file = ReferencedFile(
                id: UUID(),
                path: path,
                contentPreview: content,
                isIncluded: true
            )
            referencedFiles.append(file)
        } catch {
            errorMessage = "引用文件失败: \(error.localizedDescription)"
        }
    }
    
    func removeReferencedFile(id: UUID) {
        referencedFiles.removeAll { $0.id == id }
    }
    
    func addSelectedTextSnippet(_ text: String) {
        guard !text.isEmpty else { return }
        let snippet = SelectedTextSnippet(content: text)
        selectedTextSnippets.append(snippet)
    }
    
    func removeSelectedTextSnippet(id: UUID) {
        selectedTextSnippets.removeAll { $0.id == id }
    }
    
    func clearSelectedTextSnippets() {
        selectedTextSnippets.removeAll()
    }
    
    func clearConversation() {
        messages.removeAll()
        pendingEdit = nil
        errorMessage = nil
        currentConversationId = nil
        selectedTextSnippets.removeAll()
        state = .idle
        eventBus.clear()
    }
    
    func cancelRun() {
        currentRunTask?.cancel()
        currentRunTask = nil
        state = .idle
        eventBus.error("用户取消运行", code: "CANCELLED")
        eventBus.finishRun()
    }
    
    /// 发送用户消息并获取 AI 回复，支持多轮工具调用与流式输出
    func sendMessage(_ text: String, documentText: String) {
        currentRunTask?.cancel()
        let snippets = selectedTextSnippets
        clearSelectedTextSnippets()
        currentRunTask = Task { [weak self] in
            guard let self = self else { return }
            await self.performSendMessage(text, documentText: documentText, selectedSnippets: snippets)
        }
    }
    
    private func performSendMessage(_ text: String, documentText: String, selectedSnippets: [SelectedTextSnippet]) async {
        ensureConversationId()
        let (cleanText, referencedPaths) = FileContextService.shared.extractFileReferences(from: text)
        
        for path in referencedPaths {
            await addReferencedFile(path: path)
        }
        
        let userMessage = ChatMessage(
            role: .user,
            content: cleanText,
            referencedFiles: referencedFiles
        )
        messages.append(userMessage)
        
        // 意图分类：决定本轮工具优先级
        let intent = await IntentRecognitionService.shared.classify(
            text: cleanText,
            documentText: documentText,
            availableTools: ToolRegistry.shared.allDefinitions + MCPManager.shared.discoveredTools,
            configuration: configuration,
            apiKey: apiKey
        )
        await MainActor.run {
            self.lastIntentClassification = intent
        }
        let preferredTools = intent.confidence >= 0.6 ? intent.preferredTools : []
        
        let annotations = AnnotationService.shared.unresolvedAnnotations(for: currentFilePath)
        await performChatRound(
            documentText: documentText,
            preferredTools: preferredTools,
            restrictTools: false,
            selectedSnippets: selectedSnippets,
            annotations: annotations
        )
        
        // 基于本轮对话启发式更新用户画像
        if let lastAssistantMessage = messages.last(where: { $0.role == .assistant }) {
            MemoryService.shared.recordInteraction(
                userMessage: userMessage.content,
                assistantMessage: lastAssistantMessage.content
            )
        } else {
            MemoryService.shared.recordInteraction(userMessage: userMessage.content, assistantMessage: nil)
        }
    }
    
    /// 执行某个 Skill
    func runSkill(_ skill: SkillDefinition, documentText: String, extraInput: String = "") {
        currentRunTask?.cancel()
        let snippets = selectedTextSnippets
        clearSelectedTextSnippets()
        currentRunTask = Task { [weak self] in
            guard let self = self else { return }
            self.ensureConversationId()
            let prompt = skill.promptTemplate + "\n\n" + (extraInput.isEmpty ? "" : "用户补充要求：\(extraInput)\n\n") + documentText
            let userMessage = ChatMessage(role: .user, content: "[Skill: \(skill.name)]\n\(prompt)")
            self.messages.append(userMessage)
            let annotations = AnnotationService.shared.unresolvedAnnotations(for: self.currentFilePath)
            await self.performChatRound(
                documentText: documentText,
                preferredTools: skill.suggestedTools,
                restrictTools: true,
                selectedSnippets: snippets,
                annotations: annotations
            )
        }
    }
    
    private func performChatRound(
        documentText: String,
        preferredTools: [String] = [],
        restrictTools: Bool = false,
        selectedSnippets: [SelectedTextSnippet],
        annotations: [Annotation] = []
    ) async {
        state = .streaming
        errorMessage = nil
        
        let runId = UUID().uuidString
        eventBus.clear()
        eventBus.startRun(threadId: threadId, runId: runId)
        
        // 同步当前文档内容到 UserDefaults，供 search_in_document 工具读取
        UserDefaults.standard.set(documentText, forKey: "techmarkdown.currentDocumentText")
        
        // 收集可用工具：内置工具 + MCP 发现工具
        var availableTools = ToolRegistry.shared.allDefinitions
        availableTools.append(contentsOf: mcpManager.discoveredTools)
        if !preferredTools.isEmpty {
            if restrictTools {
                // Skill 模式：严格限制在建议工具内
                availableTools = availableTools.filter { preferredTools.contains($0.name) }
            } else {
                // 意图路由模式：仅调整工具排序，优先展示相关工具
                let preferredSet = Set(preferredTools)
                availableTools.sort { a, b in
                    let aPreferred = preferredSet.contains(a.name)
                    let bPreferred = preferredSet.contains(b.name)
                    if aPreferred == bPreferred { return false }
                    return aPreferred && !bPreferred
                }
            }
        }
        
        do {
            try await executeStreamingRound(
                documentText: documentText,
                selectedSnippets: selectedSnippets,
                tools: availableTools,
                runId: runId,
                annotations: annotations
            )
        } catch {
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
                state = .error(error.localizedDescription)
                eventBus.error(error.localizedDescription)
            }
        }
        
        eventBus.finishRun()
        if case .error = state {} else if state != .waitingForUserConfirmation {
            state = .finished
        }
        currentRunTask = nil
        saveCurrentConversation()
    }
    
    /// 一轮流式对话：流式获取助手回复，若包含工具调用则执行并继续
    private func executeStreamingRound(
        documentText: String,
        selectedSnippets: [SelectedTextSnippet],
        tools: [ToolDefinition],
        runId: String,
        annotations: [Annotation] = []
    ) async throws {
        let messageId = UUID().uuidString
        var streamedContent = ""
        var streamedReasoning = ""
        var parsedToolCalls: [ToolCall] = []
        var streamingToolCalls: [String: StreamingToolCallAccumulator] = [:]
        
        eventBus.emit(
            .textMessageStart,
            messageId: messageId,
            payload: TextMessageStartPayload(messageId: messageId, role: "assistant")
        )
        
        let stream = AIService.shared.chatStream(
            messages: messages,
            documentText: documentText,
            referencedFiles: referencedFiles,
            selectedTextSnippets: selectedSnippets,
            tools: tools,
            configuration: configuration,
            apiKey: apiKey,
            threadId: threadId,
            runId: runId,
            messageId: messageId,
            annotations: annotations
        )
        
        for try await event in stream {
            // 将底层流事件也加入总线，便于 UI 显示
            eventBus.relay(event)
            
            switch event.type {
            case .textMessageContent:
                if let payload = event.payload as? TextMessageContentPayload {
                    streamedContent.append(payload.delta)
                    self.currentStreamingContent = streamedContent
                }
            case .textMessageEnd:
                if let payload = event.payload as? TextMessageEndPayload {
                    streamedContent = payload.content
                }
            case .reasoningMessageContent:
                if let payload = event.payload as? ReasoningMessageContentPayload {
                    streamedReasoning.append(payload.delta)
                    self.currentStreamingReasoning = streamedReasoning
                }
            case .toolCallStart:
                if let payload = event.payload as? ToolCallStartPayload {
                    streamingToolCalls[payload.toolCallId] = StreamingToolCallAccumulator(
                        id: payload.toolCallId,
                        name: payload.toolCallName
                    )
                    self.currentToolCallName = payload.toolCallName
                }
            case .toolCallArgs:
                if let payload = event.payload as? ToolCallArgsPayload,
                   var accumulator = streamingToolCalls[payload.toolCallId] {
                    accumulator.arguments.append(payload.delta)
                    streamingToolCalls[payload.toolCallId] = accumulator
                }
            case .toolCallEnd:
                if let payload = event.payload as? ToolCallEndPayload,
                   let accumulator = streamingToolCalls[payload.toolCallId] {
                    parsedToolCalls.append(ToolCall(
                        id: accumulator.id,
                        function: ToolCallFunction(
                            name: accumulator.name,
                            arguments: accumulator.arguments
                        )
                    ))
                }
            default:
                break
            }
        }
        
        eventBus.emit(
            .textMessageEnd,
            messageId: messageId,
            payload: TextMessageEndPayload(messageId: messageId, content: streamedContent)
        )
        self.currentStreamingContent = ""
        self.currentStreamingReasoning = ""
        self.currentToolCallName = nil

        // 兜底：某些模型会把工具调用以 DSML 格式直接输出到正文中
        if let dsmlCalls = parseDSMLToolCalls(from: streamedContent), !dsmlCalls.isEmpty {
            let mappedToolCalls = dsmlCalls.compactMap { dsmlCall -> ToolCall? in
                var args = dsmlCall.arguments
                if dsmlCall.name == "apply_markdown_edit" {
                    if let edit = args["edit"] {
                        args["markdown"] = edit
                        args.removeValue(forKey: "edit")
                    }
                    if args["reason"] == nil {
                        args["reason"] = "AI 文档修改建议"
                    }
                }
                guard let data = try? JSONSerialization.data(withJSONObject: args) else { return nil }
                let argumentsString = String(data: data, encoding: .utf8) ?? "{}"
                return ToolCall(
                    id: UUID().uuidString,
                    function: ToolCallFunction(name: dsmlCall.name, arguments: argumentsString)
                )
            }
            parsedToolCalls.append(contentsOf: mappedToolCalls)

            let (prefix, _) = splitDSMLBlock(from: streamedContent)
            let cleanPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolNames = mappedToolCalls.map { $0.name }.joined(separator: ", ")
            if mappedToolCalls.allSatisfy({ $0.name == "apply_markdown_edit" }) && cleanPrefix.isEmpty {
                streamedContent = "已生成文档修改建议，请在侧边栏确认应用。"
            } else if cleanPrefix.isEmpty {
                streamedContent = "正在执行工具：\(toolNames)…"
            } else {
                streamedContent = "\(cleanPrefix)\n\n（已解析为工具调用：\(toolNames)）"
            }
        }

        let assistantMessage = ChatMessage(
            role: .assistant,
            content: streamedContent,
            toolCalls: parsedToolCalls.isEmpty ? nil : parsedToolCalls,
            reasoningContent: streamedReasoning.isEmpty ? nil : streamedReasoning
        )
        messages.append(assistantMessage)
        
        // 处理工具调用（并发执行）
        if !parsedToolCalls.isEmpty {
            state = .executingTools
            eventBus.emit(
                .stepStarted,
                messageId: messageId,
                payload: StepStartedPayload(stepName: "工具执行")
            )
            
            let results = await executeToolCallsConcurrently(parsedToolCalls, messageId: messageId)
            
            for (_, result) in results {
                messages.append(ChatMessage(
                    role: .tool,
                    content: result.output,
                    toolCallID: result.toolCallID
                ))
                
                eventBus.emit(
                    .toolCallResult,
                    messageId: messageId,
                    toolCallId: result.toolCallID,
                    payload: ToolCallResultPayload(
                        messageId: messageId,
                        toolCallId: result.toolCallID,
                        content: result.output,
                        role: "tool",
                        error: result.isError ? result.output : nil
                    )
                )
            }
            
            eventBus.emit(
                .stepFinished,
                messageId: messageId,
                payload: StepFinishedPayload(stepName: "工具执行")
            )
            
            // 工具结果回填后再请求一次 AI，获取最终回复；保留工具让 AI 可以继续多步调用
            try await executeStreamingRound(
                documentText: documentText,
                selectedSnippets: selectedSnippets,
                tools: tools,
                runId: runId,
                annotations: annotations
            )
        }
    }
    
    /// 并发执行多个工具调用，并保持原始顺序返回
    private func executeToolCallsConcurrently(
        _ toolCalls: [ToolCall],
        messageId: String
    ) async -> [(ToolCall, ToolResult)] {
        return await withTaskGroup(of: (Int, ToolResult).self) { group in
            for (index, toolCall) in toolCalls.enumerated() {
                eventBus.emit(
                    .toolCallEnd,
                    messageId: messageId,
                    toolCallId: toolCall.id,
                    payload: ToolCallEndPayload(toolCallId: toolCall.id)
                )
                group.addTask {
                    let result = await ToolRegistry.shared.execute(toolCall: toolCall)
                    return (index, result)
                }
            }
            
            var indexedResults: [(Int, ToolCall, ToolResult)] = []
            for await (index, result) in group {
                indexedResults.append((index, toolCalls[index], result))
            }
            
            return indexedResults
                .sorted { $0.0 < $1.0 }
                .map { ($0.1, $0.2) }
        }
    }
    
    func applyPendingEdit(to text: inout String) {
        guard let edit = pendingEdit else { return }
        applySelectedHunks(Set(edit.hunks.map(\.id)), to: &text)
    }
    
    func applySelectedHunks(_ selectedIDs: Set<UUID>, to text: inout String) {
        guard let edit = pendingEdit else { return }
        VersionHistoryService.shared.saveVersion(
            text: text,
            reason: "AI 修改前快照",
            isAutoSave: true
        )
        if selectedIDs.isEmpty {
            // 未选择任何 hunk 视为全部弃用
            pendingEdit = nil
            state = .finished
            eventBus.emit(
                .stateDelta,
                payload: StateDeltaPayload(patch: [
                    StatePatchOperation(op: "remove", path: "/pendingEdit", value: nil)
                ])
            )
            saveCurrentConversation()
            return
        }
        text = DiffService.applySelectedHunks(
            original: edit.originalText,
            hunks: edit.hunks,
            selectedIDs: selectedIDs
        )
        VersionHistoryService.shared.saveVersion(
            text: text,
            reason: edit.reason,
            isAutoSave: true
        )
        pendingEdit = nil
        state = .finished
        eventBus.emit(
            .stateDelta,
            payload: StateDeltaPayload(patch: [
                StatePatchOperation(op: "remove", path: "/pendingEdit", value: nil)
            ])
        )
        saveCurrentConversation()
    }
    
    func discardPendingEdit() {
        pendingEdit = nil
        state = .finished
        eventBus.emit(
            .stateDelta,
            payload: StateDeltaPayload(patch: [
                StatePatchOperation(op: "remove", path: "/pendingEdit", value: nil)
            ])
        )
    }
    
    // MARK: - Conversation Persistence
    
    private func ensureConversationId() {
        if currentConversationId == nil {
            currentConversationId = UUID()
        }
    }
    
    private func saveCurrentConversation() {
        guard let conversationId = currentConversationId, !messages.isEmpty else { return }
        let title = ConversationHistoryService.shared.generateTitle(from: messages)
        let conversation = Conversation(
            id: conversationId,
            title: title,
            createdAt: Date(),
            updatedAt: Date(),
            messages: messages
        )
        ConversationHistoryService.shared.save(conversation)
    }
    
    func loadConversation(_ conversation: Conversation) {
        messages = conversation.messages
        currentConversationId = conversation.id
        pendingEdit = nil
        state = .idle
        eventBus.clear()
    }
    
    func deleteConversation(_ conversation: Conversation) {
        ConversationHistoryService.shared.delete(id: conversation.id)
        if currentConversationId == conversation.id {
            clearConversation()
        }
    }
}

private struct DSMLToolCall {
    let name: String
    let arguments: [String: String]
}

private func normalizeDSML(_ content: String) -> String {
    content.replacingOccurrences(of: "｜", with: "|")
}

private func splitDSMLBlock(from content: String) -> (prefix: String, block: String) {
    let normalized = normalizeDSML(content)
    let marker = "<||DSML||tool_calls>"
    guard let range = normalized.range(of: marker) else {
        return (content, "")
    }
    let prefix = String(normalized[..<range.lowerBound])
    let block = String(normalized[range.lowerBound...])
    return (prefix, block)
}

private func parseDSMLToolCalls(from content: String) -> [DSMLToolCall]? {
    let normalized = normalizeDSML(content)
    let marker = "<||DSML||tool_calls>"
    guard normalized.contains(marker) else { return nil }

    let invokePattern = #"<\|\|DSML\|\|invoke\s+name="([^"]*)">"#
    let paramPattern = #"<\|\|DSML\|\|parameter\s+name="([^"]*)"(?:\s+[^>]*)?>"#
    guard let invokeRegex = try? NSRegularExpression(pattern: invokePattern, options: []),
          let paramRegex = try? NSRegularExpression(pattern: paramPattern, options: []) else {
        return nil
    }

    let nsRange = NSRange(normalized.startIndex..., in: normalized)
    let invokeMatches = invokeRegex.matches(in: normalized, options: [], range: nsRange)
    guard !invokeMatches.isEmpty else { return nil }

    var calls: [DSMLToolCall] = []
    for (i, invokeMatch) in invokeMatches.enumerated() {
        guard let nameRange = Range(invokeMatch.range(at: 1), in: normalized) else { continue }
        let name = String(normalized[nameRange])

        let segmentStart = invokeMatch.range(at: 0).upperBound
        let segmentEnd = (i + 1 < invokeMatches.count)
            ? invokeMatches[i + 1].range(at: 0).location
            : normalized.utf16.count
        guard segmentEnd > segmentStart,
              let segmentRange = Range(NSRange(location: segmentStart, length: segmentEnd - segmentStart), in: normalized) else {
            continue
        }
        let segment = String(normalized[segmentRange])

        let paramMatches = paramRegex.matches(in: segment, options: [], range: NSRange(segment.startIndex..., in: segment))
        var args: [String: String] = [:]
        for (j, paramMatch) in paramMatches.enumerated() {
            guard let paramNameRange = Range(paramMatch.range(at: 1), in: segment) else { continue }
            let paramName = String(segment[paramNameRange])

            let valueStart = paramMatch.range(at: 0).upperBound
            let valueEnd = (j + 1 < paramMatches.count)
                ? paramMatches[j + 1].range(at: 0).location
                : segment.utf16.count
            guard valueEnd > valueStart,
                  let valueRange = Range(NSRange(location: valueStart, length: valueEnd - valueStart), in: segment) else {
                continue
            }
            var value = String(segment[valueRange])
            if let closeRange = value.range(of: "</||DSML||parameter>") {
                value = String(value[..<closeRange.lowerBound])
            }
            value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            args[paramName] = value
        }
        calls.append(DSMLToolCall(name: name, arguments: args))
    }

    return calls.isEmpty ? nil : calls
}

private struct StreamingToolCallAccumulator {
    let id: String
    var name: String
    var arguments: String = ""
}
