import Foundation
import SwiftUI
import Combine

enum AgentState: Equatable {
    case idle
    case streaming
    case executingTools
    case waitingForUserConfirmation
    case finished
    case error(String)

    var isActive: Bool {
        switch self {
        case .streaming, .executingTools:
            return true
        case .idle, .waitingForUserConfirmation, .finished, .error:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .streaming: return "生成回复中"
        case .executingTools: return "执行工具中"
        case .waitingForUserConfirmation: return "等待用户确认"
        case .finished: return "完成"
        case .error(let message): return "错误: \(message)"
        }
    }
}

/// 本地文档 Agent 协调器。
///
/// Provider token 只驱动临时 UI；Conversation / Run / RunStep 在语义边界写入本地 SQLite。
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
    var currentStreamingContent = ""
    var currentStreamingReasoning = ""
    var currentToolCallName: String?
    var connectionStatus = "未检测"
    var currentConversationId: UUID?
    var lastIntentClassification: IntentClassification?
    var currentFilePath: String?

    var currentRun: AgentRunRecord?
    var currentRunSteps: [AgentRunStep] = []
    var runHistory: [AgentRunRecord] = []
    var recoverableRun: AgentRunRecord?
    var contextNotice: String?
    var fileConversationCount = 0

    private(set) var threadId: String
    private(set) var configuration: AIProviderConfiguration
    private var apiKey: String
    private let mcpManager = MCPManager.shared
    private let historyService: ConversationHistoryService
    private var currentRunTask: Task<Void, Never>?
    private var currentConversationCreatedAt: Date?
    private var observers: [NSObjectProtocol] = []
    private var activeToolStepIDs: [String: UUID] = [:]

    init(
        configuration: AIProviderConfiguration = AIProviderConfiguration(),
        apiKey: String = "",
        historyService: ConversationHistoryService = .shared
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.threadId = UUID().uuidString
        self.historyService = historyService
        observePendingEditNotification()
        observePendingTextEditNotification()
        observeAddProjectFileToContextNotification()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Notifications

    private func observePendingEditNotification() {
        let observer = NotificationCenter.default.addObserver(
            forName: .pendingMarkdownEdit,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let markdown = notification.userInfo?["markdown"] as? String,
                let reason = notification.userInfo?["reason"] as? String
            else { return }
            self.createPendingEdit(suggestedText: markdown, reason: reason)
        }
        observers.append(observer)
    }

    private func observePendingTextEditNotification() {
        let observer = NotificationCenter.default.addObserver(
            forName: .pendingTextEdit,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let text = notification.userInfo?["text"] as? String,
                let reason = notification.userInfo?["reason"] as? String
            else { return }
            self.createPendingEdit(suggestedText: text, reason: reason)
        }
        observers.append(observer)
    }

    private func observeAddProjectFileToContextNotification() {
        let observer = NotificationCenter.default.addObserver(
            forName: .addProjectFileToContext,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let path = notification.userInfo?["path"] as? String
            else { return }
            Task {
                await self.addProjectFileToContext(path: path)
            }
        }
        observers.append(observer)
    }

    private func createPendingEdit(suggestedText: String, reason: String) {
        let currentText = UserDefaults.standard.string(forKey: "techmarkdown.currentDocumentText") ?? ""
        let edit = PendingEdit(
            originalText: currentText,
            suggestedText: suggestedText,
            reason: reason,
            hunks: DiffService.computeHunks(original: currentText, suggested: suggestedText),
            runID: currentRun?.id
        )
        pendingEdit = edit
        state = .waitingForUserConfirmation

        if let runID = currentRun?.id {
            transitionCurrentRun(to: .awaitingApproval)
            _ = appendStep(
                runID: runID,
                kind: .approval,
                status: .waiting,
                title: "等待确认文档修改",
                detail: reason
            )
        }

        eventBus.emit(
            .custom,
            messageId: UUID().uuidString,
            payload: CustomPayload(name: "PENDING_EDIT_CREATED", value: reason)
        )
        eventBus.emit(
            .stateDelta,
            payload: StateDeltaPayload(
                patch: [StatePatchOperation(op: "add", path: "/pendingEdit", value: reason)]
            )
        )
        saveCurrentConversation()
    }

    // MARK: - Configuration

    func updateConfiguration(_ config: AIProviderConfiguration, apiKey: String) {
        configuration = config
        self.apiKey = apiKey
    }

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
                let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                connectionStatus = trimmed.isEmpty
                    ? "连接成功，但模型返回为空"
                    : "连接成功: \(trimmed.prefix(30))"
            } catch {
                connectionStatus = "连接失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Context

    func addReferencedFile(path: String) async {
        do {
            let content = try await FileContextService.shared.readFile(at: path, maxLength: 50_000)
            let file = ReferencedFile(
                id: UUID(),
                path: path,
                contentPreview: content,
                isIncluded: true
            )
            if !referencedFiles.contains(where: { $0.path == path }) {
                referencedFiles.append(file)
                saveCurrentConversation()
            }
        } catch {
            errorMessage = "引用文件失败: \(error.localizedDescription)"
        }
    }

    func removeReferencedFile(id: UUID) {
        referencedFiles.removeAll { $0.id == id }
        saveCurrentConversation()
    }

    func toggleReferencedFile(id: UUID) {
        guard let index = referencedFiles.firstIndex(where: { $0.id == id }) else { return }
        referencedFiles[index].isIncluded.toggle()
        saveCurrentConversation()
    }

    func addSelectedTextSnippet(_ text: String) {
        guard !text.isEmpty else { return }
        selectedTextSnippets.append(SelectedTextSnippet(content: text))
    }

    func removeSelectedTextSnippet(id: UUID) {
        selectedTextSnippets.removeAll { $0.id == id }
    }

    func clearSelectedTextSnippets() {
        selectedTextSnippets.removeAll()
    }

    func updateCurrentFile(path: String?, documentText: String) {
        currentFilePath = path
        refreshFileConversationCount()

        guard
            let conversationID = currentConversationId,
            let conversation = historyService.load(id: conversationID),
            conversation.context.primaryFilePath == path
        else {
            contextNotice = nil
            return
        }

        if
            let fingerprint = conversation.context.documentFingerprint,
            !documentText.isEmpty,
            fingerprint != ContentFingerprint.make(documentText)
        {
            contextNotice = "当前文件已更新，后续对话会使用最新正文。"
        } else {
            contextNotice = nil
        }
    }

    // MARK: - User Actions

    /// 保存当前会话并切换到一个全新的上下文。
    /// 与“清空对话”不同，这个动作不会丢失当前会话的历史记录。
    func startNewConversation(documentText: String = "") {
        if isProcessing {
            cancelRun()
        }
        saveCurrentConversation(documentText: documentText.isEmpty ? nil : documentText)
        clearConversation()
    }

    func clearConversation() {
        currentRunTask?.cancel()
        currentRunTask = nil
        messages.removeAll()
        pendingEdit = nil
        errorMessage = nil
        currentConversationId = nil
        currentConversationCreatedAt = nil
        threadId = UUID().uuidString
        selectedTextSnippets.removeAll()
        referencedFiles.removeAll()
        currentRun = nil
        currentRunSteps.removeAll()
        runHistory.removeAll()
        recoverableRun = nil
        contextNotice = nil
        currentStreamingContent = ""
        currentStreamingReasoning = ""
        currentToolCallName = nil
        lastIntentClassification = nil
        state = .idle
        eventBus.clear()
        refreshFileConversationCount()
    }

    func cancelRun() {
        guard currentRunTask != nil || currentRun?.status.isTerminal == false else { return }
        currentRunTask?.cancel()
        markOpenSteps(status: .cancelled, detail: "用户已停止运行")
        transitionCurrentRun(to: .cancelled, error: "用户停止运行")
        state = .idle
        currentStreamingContent = ""
        currentStreamingReasoning = ""
        currentToolCallName = nil
        eventBus.error("用户取消运行", code: "CANCELLED")
        eventBus.finishRun()
        saveCurrentConversation()
    }

    func sendMessage(_ text: String, documentText: String) {
        currentRunTask?.cancel()
        let snippets = selectedTextSnippets
        let referenceSnapshot = referencedFiles.filter(\.isIncluded)
        clearSelectedTextSnippets()
        currentRunTask = Task { [weak self] in
            guard let self else { return }
            await self.performSendMessage(
                text,
                documentText: documentText,
                selectedSnippets: snippets,
                referencedFiles: referenceSnapshot
            )
        }
    }

    func runSkill(_ skill: SkillDefinition, documentText: String, extraInput: String = "") {
        currentRunTask?.cancel()
        let snippets = selectedTextSnippets
        let referenceSnapshot = referencedFiles.filter(\.isIncluded)
        clearSelectedTextSnippets()
        currentRunTask = Task { [weak self] in
            guard let self else { return }
            self.ensureConversationID()
            let prompt = skill.promptTemplate
                + "\n\n"
                + (extraInput.isEmpty ? "" : "用户补充要求：\(extraInput)\n\n")
                + documentText
            var userMessage = ChatMessage(
                role: .user,
                content: "[Skill: \(skill.name)]\n\(prompt)",
                referencedFiles: referenceSnapshot
            )
            self.messages.append(userMessage)
            self.saveCurrentConversation(documentText: documentText)

            let run = self.beginRun(checkpointMessageCount: self.messages.count)
            userMessage.runID = run.id
            self.messages[self.messages.count - 1] = userMessage
            _ = self.appendStep(
                runID: run.id,
                kind: .intent,
                status: .completed,
                title: "运行 Skill：\(skill.name)",
                detail: skill.description,
                endedAt: Date()
            )

            let annotations = AnnotationService.shared.unresolvedAnnotations(for: self.currentFilePath)
            await self.performChatRound(
                runID: run.id,
                documentText: documentText,
                preferredTools: skill.suggestedTools,
                restrictTools: true,
                allowsDocumentProposal: skill.suggestedTools.contains {
                    $0 == "apply_markdown_edit" || $0 == "apply_text_edit"
                },
                selectedSnippets: snippets,
                referencedFiles: referenceSnapshot,
                annotations: annotations
            )
        }
    }

    func resumeLastRun(documentText: String) {
        guard let previous = recoverableRun else { return }
        currentRunTask?.cancel()
        pendingEdit = nil
        errorMessage = nil

        let run = beginRun(
            checkpointMessageCount: messages.count,
            parentRunID: previous.id
        )
        _ = appendStep(
            runID: run.id,
            kind: .context,
            status: .completed,
            title: "从安全检查点恢复",
            detail: "保留已完成的消息和工具回执，只继续未完成步骤",
            endedAt: Date()
        )

        currentRunTask = Task { [weak self] in
            guard let self else { return }
            do {
                let unresolvedCalls = AgentRecoveryPlanner.unresolvedToolCalls(in: self.messages)
                if !unresolvedCalls.isEmpty {
                    self.transitionCurrentRun(to: .executingTool, expectedRunID: run.id)
                    self.state = .executingTools
                    let resumedTools = AgentToolPolicy.resolve(
                        ToolRegistry.shared.allDefinitions + self.mcpManager.discoveredTools,
                        preferredTools: self.lastIntentClassification?.preferredTools ?? [],
                        restrictTools: false,
                        allowsDocumentProposal: self.lastIntentClassification?.allowsDocumentProposal ?? false
                    )
                    try await self.executeToolCallsSequentially(
                        unresolvedCalls,
                        runID: run.id,
                        allowedToolNames: Set(resumedTools.map(\.name))
                    )
                }
                let annotations = AnnotationService.shared.unresolvedAnnotations(for: self.currentFilePath)
                let referenceSnapshot = self.messages
                    .last(where: { $0.role == .user && !$0.referencedFiles.isEmpty })?
                    .referencedFiles
                    ?? self.referencedFiles.filter(\.isIncluded)
                await self.performChatRound(
                    runID: run.id,
                    documentText: documentText,
                    selectedSnippets: [],
                    referencedFiles: referenceSnapshot,
                    annotations: annotations
                )
            } catch is CancellationError {
                self.finishCancelledRun(runID: run.id)
            } catch {
                self.markOpenSteps(status: .failed, detail: error.localizedDescription)
                self.transitionCurrentRun(
                    to: .failed,
                    error: error.localizedDescription,
                    expectedRunID: run.id
                )
                self.state = .error(error.localizedDescription)
                self.errorMessage = error.localizedDescription
                self.saveCurrentConversation(documentText: documentText)
            }
        }
    }

    // MARK: - Send / Classify

    private func performSendMessage(
        _ text: String,
        documentText: String,
        selectedSnippets: [SelectedTextSnippet],
        referencedFiles referenceSnapshot: [ReferencedFile]
    ) async {
        ensureConversationID()
        let (cleanText, referencedPaths) = FileContextService.shared.extractFileReferences(from: text)

        for path in referencedPaths {
            if Task.isCancelled {
                currentRunTask = nil
                return
            }
            await addReferencedFile(path: path)
        }

        var userMessage = ChatMessage(
            role: .user,
            content: cleanText,
            referencedFiles: referenceSnapshot
        )
        messages.append(userMessage)
        saveCurrentConversation(documentText: documentText)

        let run = beginRun(checkpointMessageCount: messages.count)
        userMessage.runID = run.id
        messages[messages.count - 1] = userMessage
        saveCurrentConversation(documentText: documentText)

        _ = appendStep(
            runID: run.id,
            kind: .context,
            status: .completed,
            title: "确认本轮资料与分析对象",
            detail: contextDetail(
                userText: cleanText,
                documentText: documentText,
                referencedFiles: referenceSnapshot,
                selectedSnippets: selectedSnippets
            ),
            endedAt: Date()
        )

        transitionCurrentRun(to: .retrieving, expectedRunID: run.id)
        let intentStepID = appendStep(
            runID: run.id,
            kind: .intent,
            title: "识别任务目标与操作边界",
            detail: "正在判断任务目标、输出位置以及是否允许生成文档修改建议"
        )
        let intent = await IntentRecognitionService.shared.classify(
            text: cleanText,
            documentText: documentText,
            availableTools: ToolRegistry.shared.allDefinitions + mcpManager.discoveredTools,
            configuration: configuration,
            apiKey: apiKey
        )

        guard !Task.isCancelled else {
            finishCancelledRun(runID: run.id)
            return
        }
        lastIntentClassification = intent
        updateStep(
            id: intentStepID,
            status: .completed,
            detail: """
            任务目标：\(intent.goal.displayName)
            工具路由：\(intent.intent.displayName)
            输出位置：\(intent.output.displayName)
            修改权限：\(intent.mutationPolicy.displayName)
            置信度：\(Int(intent.confidence * 100))%
            判断依据：\(intent.reason)
            识别证据：\(intent.evidence.isEmpty ? "未发现明确写回指令，采用只读默认值" : intent.evidence.joined(separator: "、"))
            建议工具：\(intent.preferredTools.isEmpty ? "无需工具，直接基于资料回答" : intent.preferredTools.joined(separator: "、"))
            """,
            endedAt: Date()
        )

        let annotations = AnnotationService.shared.unresolvedAnnotations(for: currentFilePath)
        await performChatRound(
            runID: run.id,
            documentText: documentText,
            preferredTools: intent.confidence >= 0.6 ? intent.preferredTools : [],
            allowsDocumentProposal: intent.allowsDocumentProposal,
            selectedSnippets: selectedSnippets,
            referencedFiles: referenceSnapshot,
            annotations: annotations
        )

        if let lastAssistantMessage = messages.last(where: { $0.role == .assistant }) {
            MemoryService.shared.recordInteraction(
                userMessage: userMessage.content,
                assistantMessage: lastAssistantMessage.content
            )
        } else {
            MemoryService.shared.recordInteraction(
                userMessage: userMessage.content,
                assistantMessage: nil
            )
        }
    }

    // MARK: - Bounded Runtime

    private func performChatRound(
        runID: UUID,
        documentText: String,
        preferredTools: [String] = [],
        restrictTools: Bool = false,
        allowsDocumentProposal: Bool = false,
        selectedSnippets: [SelectedTextSnippet],
        referencedFiles: [ReferencedFile],
        annotations: [Annotation] = []
    ) async {
        state = .streaming
        errorMessage = nil
        eventBus.clear()
        eventBus.startRun(threadId: threadId, runId: runID.uuidString)
        UserDefaults.standard.set(documentText, forKey: "techmarkdown.currentDocumentText")

        let availableTools = AgentToolPolicy.resolve(
            ToolRegistry.shared.allDefinitions + mcpManager.discoveredTools,
            preferredTools: preferredTools,
            restrictTools: restrictTools,
            allowsDocumentProposal: allowsDocumentProposal
        )

        do {
            transitionCurrentRun(to: .generating, expectedRunID: runID)
            try await executeAgentLoop(
                runID: runID,
                documentText: documentText,
                selectedSnippets: selectedSnippets,
                referencedFiles: referencedFiles,
                tools: availableTools,
                annotations: annotations
            )
            try Task.checkCancellation()

            if pendingEdit != nil {
                transitionCurrentRun(to: .awaitingApproval, expectedRunID: runID)
                state = .waitingForUserConfirmation
            } else {
                transitionCurrentRun(to: .finalizing, expectedRunID: runID)
                let persistenceStepID = appendStep(
                    runID: runID,
                    kind: .persistence,
                    title: "保存对话与运行记录",
                    detail: "正在写入本地工作区"
                )
                saveCurrentConversation(documentText: documentText)
                updateStep(
                    id: persistenceStepID,
                    status: .completed,
                    detail: "已保存，可在应用重启后继续",
                    endedAt: Date()
                )
                transitionCurrentRun(to: .completed, expectedRunID: runID)
                state = .finished
            }
        } catch is CancellationError {
            finishCancelledRun(runID: runID)
        } catch {
            markOpenSteps(status: .failed, detail: error.localizedDescription)
            _ = appendStep(
                runID: runID,
                kind: .error,
                status: .failed,
                title: "运行失败",
                detail: error.localizedDescription,
                endedAt: Date()
            )
            errorMessage = error.localizedDescription
            state = .error(error.localizedDescription)
            transitionCurrentRun(
                to: .failed,
                error: error.localizedDescription,
                expectedRunID: runID
            )
            eventBus.error(error.localizedDescription)
        }

        eventBus.finishRun()
        if currentRun?.id == runID {
            currentRunTask = nil
        }
        saveCurrentConversation(documentText: documentText)
    }

    private func executeAgentLoop(
        runID: UUID,
        documentText: String,
        selectedSnippets: [SelectedTextSnippet],
        referencedFiles: [ReferencedFile],
        tools: [ToolDefinition],
        annotations: [Annotation]
    ) async throws {
        var totalToolCalls = currentRun?.toolCallCount ?? 0

        for round in 1...AgentRuntimePolicy.maximumModelRounds {
            try Task.checkCancellation()
            updateRunCounters(modelRoundCount: round, toolCallCount: totalToolCalls)
            transitionCurrentRun(to: .generating, expectedRunID: runID)
            state = .streaming

            let toolCalls = try await streamModelTurn(
                runID: runID,
                round: round,
                documentText: documentText,
                selectedSnippets: selectedSnippets,
                referencedFiles: referencedFiles,
                tools: tools,
                annotations: annotations
            )

            if toolCalls.isEmpty {
                return
            }

            totalToolCalls += toolCalls.count
            guard totalToolCalls <= AgentRuntimePolicy.maximumToolCalls else {
                throw AgentRuntimeError.toolLimitExceeded(AgentRuntimePolicy.maximumToolCalls)
            }
            updateRunCounters(modelRoundCount: round, toolCallCount: totalToolCalls)
            transitionCurrentRun(to: .executingTool, expectedRunID: runID)
            state = .executingTools
            try await executeToolCallsSequentially(
                toolCalls,
                runID: runID,
                allowedToolNames: Set(tools.map(\.name))
            )
            if pendingEdit != nil {
                return
            }
        }

        throw AgentRuntimeError.modelRoundLimitExceeded(AgentRuntimePolicy.maximumModelRounds)
    }

    private func streamModelTurn(
        runID: UUID,
        round: Int,
        documentText: String,
        selectedSnippets: [SelectedTextSnippet],
        referencedFiles: [ReferencedFile],
        tools: [ToolDefinition],
        annotations: [Annotation]
    ) async throws -> [ToolCall] {
        let messageID = UUID().uuidString
        var streamedContent = ""
        var parsedToolCalls: [ToolCall] = []
        var streamingToolCalls: [String: StreamingToolCallAccumulator] = [:]
        var reasoningSignalCharacterCount = 0
        var lastVisibleUpdate = Date.distantPast
        let allowedToolNames = Set(tools.map(\.name))
        let lastUserText = messages.last(where: { $0.role == .user })?.content ?? ""
        let contextResolution = AIContextResolver.resolve(
            userText: lastUserText,
            currentFilePath: currentFilePath,
            referencedFiles: referencedFiles
        )

        let reasoningStepID = appendStep(
            runID: runID,
            kind: .reasoningSummary,
            title: "分析路径与依据",
            detail: """
            本轮目标：\(contextResolution.focus.displayName)
            主要资料：\(contextResolution.primarySourceNames.isEmpty ? "当前编辑文档" : contextResolution.primarySourceNames.joined(separator: "、"))
            目标选择依据：\(contextResolution.explanation)
            执行路径：先基于已提供资料形成回答；只有资料不足或任务要求操作时才调用工具。
            输出要求：结构化 Markdown，标题、段落和列表分块显示。
            """
        )

        let generationStepID = appendStep(
            runID: runID,
            kind: .generation,
            title: round == 1 ? "生成回答" : "结合工具结果继续分析",
            detail: "模型请求第 \(round) 轮"
        )

        eventBus.emit(
            .textMessageStart,
            messageId: messageID,
            payload: TextMessageStartPayload(messageId: messageID, role: "assistant")
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
            runId: runID.uuidString,
            messageId: messageID,
            currentFilePath: currentFilePath,
            annotations: annotations
        )

        do {
            for try await event in stream {
                try Task.checkCancellation()
                eventBus.relay(event)

                switch event.type {
                case .textMessageContent:
                    if let payload = event.payload as? TextMessageContentPayload {
                        streamedContent.append(payload.delta)
                        let now = Date()
                        if now.timeIntervalSince(lastVisibleUpdate) >= 0.04 {
                            currentStreamingContent = streamedContent
                            lastVisibleUpdate = now
                        }
                    }
                case .textMessageEnd:
                    if let payload = event.payload as? TextMessageEndPayload {
                        streamedContent = payload.content
                    }
                case .reasoningMessageContent:
                    if let payload = event.payload as? ReasoningMessageContentPayload {
                        reasoningSignalCharacterCount += payload.delta.count
                    }
                    currentStreamingReasoning = "正在核对分析对象、资料依据与回答结构…"
                case .toolCallStart:
                    if let payload = event.payload as? ToolCallStartPayload {
                        guard allowedToolNames.contains(payload.toolCallName) else {
                            activeToolStepIDs[payload.toolCallId] = appendStep(
                                runID: runID,
                                kind: .toolCall,
                                status: .failed,
                                title: "已阻止未授权工具调用",
                                detail: "本轮操作边界不允许调用 \(payload.toolCallName)",
                                toolName: payload.toolCallName,
                                endedAt: Date()
                            )
                            break
                        }
                        streamingToolCalls[payload.toolCallId] = StreamingToolCallAccumulator(
                            id: payload.toolCallId,
                            name: payload.toolCallName
                        )
                        if activeToolStepIDs[payload.toolCallId] == nil {
                            activeToolStepIDs[payload.toolCallId] = appendStep(
                                runID: runID,
                                kind: .toolCall,
                                title: toolDisplayName(payload.toolCallName),
                                detail: "正在准备工具参数",
                                toolName: payload.toolCallName
                            )
                        }
                        currentToolCallName = payload.toolCallName
                    }
                case .toolCallArgs:
                    if
                        let payload = event.payload as? ToolCallArgsPayload,
                        var accumulator = streamingToolCalls[payload.toolCallId]
                    {
                        accumulator.arguments.append(payload.delta)
                        streamingToolCalls[payload.toolCallId] = accumulator
                    }
                case .toolCallEnd:
                    if
                        let payload = event.payload as? ToolCallEndPayload,
                        let accumulator = streamingToolCalls[payload.toolCallId],
                        !parsedToolCalls.contains(where: { $0.id == accumulator.id })
                    {
                        let call = ToolCall(
                            id: accumulator.id,
                            function: ToolCallFunction(
                                name: accumulator.name,
                                arguments: accumulator.arguments
                            )
                        )
                        parsedToolCalls.append(call)
                        if let stepID = activeToolStepIDs[payload.toolCallId] {
                            updateStep(
                                id: stepID,
                                status: .waiting,
                                detail: summarizeToolArguments(
                                    name: accumulator.name,
                                    arguments: accumulator.arguments
                                )
                            )
                        }
                    }
                default:
                    break
                }
            }
        } catch {
            updateStep(
                id: generationStepID,
                status: .failed,
                detail: error.localizedDescription,
                endedAt: Date()
            )
            throw error
        }

        eventBus.emit(
            .textMessageEnd,
            messageId: messageID,
            payload: TextMessageEndPayload(messageId: messageID, content: streamedContent)
        )

        updateStep(
            id: reasoningStepID,
            status: .completed,
            detail: """
            本轮目标：\(contextResolution.focus.displayName)
            实际使用的主要资料：\(contextResolution.primarySourceNames.isEmpty ? "当前编辑文档" : contextResolution.primarySourceNames.joined(separator: "、"))
            目标选择依据：\(contextResolution.explanation)
            工具决策：\(parsedToolCalls.isEmpty ? "资料足够，未调用工具" : "请求 \(parsedToolCalls.count) 个工具：" + parsedToolCalls.map(\.name).joined(separator: "、"))
            模型分析信号：\(reasoningSignalCharacterCount > 0 ? "提供商返回了推理信号；为保护隐私和避免误导，仅记录可核验摘要" : "提供商未返回独立推理信号")
            """
            ,
            endedAt: Date()
        )
        updateStep(
            id: generationStepID,
            status: .completed,
            detail: """
            模型：\(configuration.model)
            轮次：第 \(round) 轮
            输出：\(streamedContent.count) 字符 · \(responseStructureDetail(streamedContent))
            结果：\(parsedToolCalls.isEmpty ? "形成最终回答" : "请求 \(parsedToolCalls.count) 个工具，等待工具结果后继续")
            """,
            endedAt: Date()
        )
        currentStreamingContent = ""
        currentStreamingReasoning = ""
        currentToolCallName = nil

        if let dsmlCalls = parseDSMLToolCalls(from: streamedContent), !dsmlCalls.isEmpty {
            let mappedToolCalls = dsmlCalls.compactMap { dsmlCall -> ToolCall? in
                guard allowedToolNames.contains(dsmlCall.name) else {
                    return nil
                }
                var arguments = dsmlCall.arguments
                if dsmlCall.name == "apply_markdown_edit" {
                    if let edit = arguments["edit"] {
                        arguments["markdown"] = edit
                        arguments.removeValue(forKey: "edit")
                    }
                    if arguments["reason"] == nil {
                        arguments["reason"] = "AI 文档修改建议"
                    }
                }
                guard let data = try? JSONSerialization.data(withJSONObject: arguments) else {
                    return nil
                }
                return ToolCall(
                    id: UUID().uuidString,
                    function: ToolCallFunction(
                        name: dsmlCall.name,
                        arguments: String(data: data, encoding: .utf8) ?? "{}"
                    )
                )
            }
            parsedToolCalls.append(contentsOf: mappedToolCalls)

            for call in mappedToolCalls {
                activeToolStepIDs[call.id] = appendStep(
                    runID: runID,
                    kind: .toolCall,
                    status: .waiting,
                    title: toolDisplayName(call.name),
                    detail: summarizeToolArguments(name: call.name, arguments: call.argumentsString),
                    toolName: call.name
                )
            }

            let (prefix, _) = splitDSMLBlock(from: streamedContent)
            let cleanPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolNames = mappedToolCalls.map(\.name).joined(separator: ", ")
            if mappedToolCalls.isEmpty {
                streamedContent = cleanPrefix.isEmpty
                    ? "本轮为只读任务，未执行未经授权的文档操作，原文保持不变。"
                    : cleanPrefix
            } else if mappedToolCalls.allSatisfy({ $0.name == "apply_markdown_edit" }) && cleanPrefix.isEmpty {
                streamedContent = "已生成文档修改建议，请在侧边栏确认应用。"
            } else if cleanPrefix.isEmpty {
                streamedContent = "正在执行工具：\(toolNames)…"
            } else {
                streamedContent = "\(cleanPrefix)\n\n（已解析为工具调用：\(toolNames)）"
            }
        }

        messages.append(
            ChatMessage(
                role: .assistant,
                content: streamedContent,
                toolCalls: parsedToolCalls.isEmpty ? nil : parsedToolCalls,
                reasoningContent: "已记录本轮分析对象、资料依据和工具决策。",
                runID: runID
            )
        )
        saveCurrentConversation(documentText: documentText)
        return parsedToolCalls
    }

    private func executeToolCallsSequentially(
        _ toolCalls: [ToolCall],
        runID: UUID,
        allowedToolNames: Set<String>
    ) async throws {
        for toolCall in toolCalls {
            try Task.checkCancellation()
            let stepID = activeToolStepIDs[toolCall.id] ?? appendStep(
                runID: runID,
                kind: .toolCall,
                title: toolDisplayName(toolCall.name),
                detail: summarizeToolArguments(name: toolCall.name, arguments: toolCall.argumentsString),
                toolName: toolCall.name
            )
            updateStep(
                id: stepID,
                status: .running,
                detail: "正在执行 · \(summarizeToolArguments(name: toolCall.name, arguments: toolCall.argumentsString))"
            )

            guard allowedToolNames.contains(toolCall.name) else {
                let detail = "已阻止：本轮操作边界不允许调用 \(toolCall.name)"
                messages.append(
                    ChatMessage(
                        role: .tool,
                        content: detail,
                        toolCallID: toolCall.id,
                        runID: runID
                    )
                )
                updateStep(
                    id: stepID,
                    status: .failed,
                    detail: detail,
                    endedAt: Date()
                )
                continue
            }

            let result: ToolResult
            if ToolRegistry.shared.containsTool(named: toolCall.name) {
                result = await ToolRegistry.shared.execute(toolCall: toolCall)
            } else {
                result = await mcpManager.execute(toolCall: toolCall)
            }

            try Task.checkCancellation()
            messages.append(
                ChatMessage(
                    role: .tool,
                    content: result.output,
                    toolCallID: result.toolCallID,
                    runID: runID
                )
            )
            updateStep(
                id: stepID,
                status: result.isError ? .failed : .completed,
                detail: summarizeToolResult(result),
                endedAt: Date()
            )

            let resultMessageID = UUID().uuidString
            eventBus.emit(
                .toolCallResult,
                messageId: resultMessageID,
                toolCallId: result.toolCallID,
                payload: ToolCallResultPayload(
                    messageId: resultMessageID,
                    toolCallId: result.toolCallID,
                    content: result.output,
                    role: "tool",
                    error: result.isError ? result.output : nil
                )
            )
            activeToolStepIDs[toolCall.id] = nil
            saveCurrentConversation()
        }
    }

    // MARK: - Approved Edits

    func applyPendingEdit(to text: inout String) {
        guard let edit = pendingEdit else { return }
        applySelectedHunks(Set(edit.hunks.map(\.id)), to: &text)
    }

    func applySelectedHunks(_ selectedIDs: Set<UUID>, to text: inout String) {
        guard let edit = pendingEdit else { return }

        guard !historyService.hasAppliedEdit(edit.id) else {
            errorMessage = "这项修改已经应用过，正文未再次更改。"
            pendingEdit = nil
            saveCurrentConversation(documentText: text)
            return
        }

        guard text == edit.originalText else {
            errorMessage = "文档在建议生成后发生了变化。为避免覆盖新内容，请重新生成修改建议。"
            if let approval = currentRunSteps.last(where: {
                $0.kind == .approval && $0.status == .waiting
            }) {
                updateStep(
                    id: approval.id,
                    status: .failed,
                    detail: "基线内容已变化，未应用",
                    endedAt: Date()
                )
            }
            return
        }

        if selectedIDs.isEmpty {
            pendingEdit = nil
            state = .finished
            completeApprovalStep(detail: "用户未选择任何修改，建议已放弃")
            transitionCurrentRun(to: .completed)
            emitPendingEditRemoved()
            saveCurrentConversation(documentText: text)
            return
        }

        let previousVersionID = VersionHistoryService.shared
            .loadAllVersions(forFilePath: currentFilePath)
            .first?
            .id
        let beforeVersionID = UUID()
        VersionHistoryService.shared.saveVersion(
            id: beforeVersionID,
            text: text,
            reason: "AI 修改前快照",
            isAutoSave: true,
            filePath: currentFilePath,
            conversationID: currentConversationId,
            runID: edit.runID,
            editID: edit.id,
            parentVersionID: previousVersionID
        )
        let updatedText = DiffService.applySelectedHunks(
            original: edit.originalText,
            hunks: edit.hunks,
            selectedIDs: selectedIDs
        )
        text = updatedText

        let receiptSaved = historyService.recordAppliedEdit(
            editID: edit.id,
            conversationID: currentConversationId,
            runID: edit.runID,
            filePath: currentFilePath,
            resultFingerprint: ContentFingerprint.make(updatedText)
        )
        if !receiptSaved {
            errorMessage = "修改已应用，但本地幂等回执保存失败。请立即保存文档。"
        }

        VersionHistoryService.shared.saveVersion(
            text: text,
            reason: edit.reason,
            isAutoSave: true,
            filePath: currentFilePath,
            conversationID: currentConversationId,
            runID: edit.runID,
            editID: edit.id,
            parentVersionID: beforeVersionID
        )
        pendingEdit = nil
        state = .finished
        completeApprovalStep(detail: "已应用 \(selectedIDs.count) 个差异块")
        transitionCurrentRun(to: .completed)
        emitPendingEditRemoved()
        saveCurrentConversation(documentText: text)
    }

    func discardPendingEdit() {
        pendingEdit = nil
        state = .finished
        completeApprovalStep(detail: "用户已放弃修改建议")
        transitionCurrentRun(to: .completed)
        emitPendingEditRemoved()
        saveCurrentConversation()
    }

    private func emitPendingEditRemoved() {
        eventBus.emit(
            .stateDelta,
            payload: StateDeltaPayload(
                patch: [StatePatchOperation(op: "remove", path: "/pendingEdit", value: nil)]
            )
        )
    }

    // MARK: - Conversation Persistence

    private func ensureConversationID() {
        if currentConversationId == nil {
            currentConversationId = UUID()
            currentConversationCreatedAt = Date()
            threadId = UUID().uuidString
        }
    }

    private func saveCurrentConversation(documentText: String? = nil) {
        guard let conversationID = currentConversationId, !messages.isEmpty else { return }
        let currentText = documentText
            ?? UserDefaults.standard.string(forKey: "techmarkdown.currentDocumentText")
            ?? ""
        let conversation = Conversation(
            id: conversationID,
            title: historyService.generateTitle(from: messages),
            createdAt: currentConversationCreatedAt ?? Date(),
            updatedAt: Date(),
            messages: messages,
            threadID: threadId,
            context: ConversationContext(
                primaryFilePath: currentFilePath,
                projectRootPath: currentFilePath.flatMap(projectRootPath),
                referencedFiles: referencedFiles,
                documentFingerprint: currentText.isEmpty ? nil : ContentFingerprint.make(currentText),
                pendingEdit: pendingEdit
            )
        )
        historyService.save(conversation)
        refreshFileConversationCount()
    }

    func loadConversation(_ conversation: Conversation, currentDocumentText: String = "") {
        messages = conversation.messages
        currentConversationId = conversation.id
        currentConversationCreatedAt = conversation.createdAt
        threadId = conversation.threadID
        referencedFiles = conversation.context.referencedFiles
        pendingEdit = conversation.context.pendingEdit
        runHistory = historyService.loadRuns(conversationID: conversation.id)
        currentRun = runHistory.last
        currentRunSteps = currentRun.map { historyService.loadSteps(runID: $0.id) } ?? []
        recoverableRun = runHistory.last.flatMap { $0.status.isRecoverable ? $0 : nil }

        if
            let expected = conversation.context.documentFingerprint,
            !currentDocumentText.isEmpty,
            expected != ContentFingerprint.make(currentDocumentText)
        {
            contextNotice = "当前文件在上次对话后已发生变化，继续时会使用最新正文。"
        } else {
            contextNotice = nil
        }
        state = pendingEdit == nil ? .idle : .waitingForUserConfirmation
        eventBus.clear()
    }

    func deleteConversation(_ conversation: Conversation) {
        historyService.delete(id: conversation.id)
        if currentConversationId == conversation.id {
            clearConversation()
        }
        refreshFileConversationCount()
    }

    func conversationsForCurrentFile() -> [Conversation] {
        guard let currentFilePath else { return [] }
        return historyService.list(forFilePath: currentFilePath)
    }

    func allConversations() -> [Conversation] {
        historyService.list()
    }

    // MARK: - Runtime Checkpoints

    @discardableResult
    private func beginRun(
        checkpointMessageCount: Int,
        parentRunID: UUID? = nil
    ) -> AgentRunRecord {
        ensureConversationID()
        saveCurrentConversation()
        let run = AgentRunRecord(
            conversationID: currentConversationId!,
            threadID: threadId,
            parentRunID: parentRunID,
            checkpointMessageCount: checkpointMessageCount
        )
        currentRun = run
        currentRunSteps.removeAll()
        activeToolStepIDs.removeAll()
        runHistory.append(run)
        recoverableRun = nil
        historyService.saveRun(run)
        return run
    }

    private func transitionCurrentRun(
        to status: AgentRunStatus,
        error: String? = nil,
        expectedRunID: UUID? = nil
    ) {
        guard var run = currentRun else { return }
        if let expectedRunID, run.id != expectedRunID {
            return
        }
        run.transition(to: status, error: error)
        currentRun = run
        if let index = runHistory.firstIndex(where: { $0.id == run.id }) {
            runHistory[index] = run
        }
        recoverableRun = status.isRecoverable ? run : nil
        historyService.saveRun(run)
    }

    private func updateRunCounters(modelRoundCount: Int, toolCallCount: Int) {
        guard var run = currentRun else { return }
        run.modelRoundCount = modelRoundCount
        run.toolCallCount = toolCallCount
        run.updatedAt = Date()
        currentRun = run
        if let index = runHistory.firstIndex(where: { $0.id == run.id }) {
            runHistory[index] = run
        }
        historyService.saveRun(run)
    }

    @discardableResult
    private func appendStep(
        runID: UUID,
        kind: AgentRunStepKind,
        status: AgentRunStepStatus = .running,
        title: String,
        detail: String = "",
        toolName: String? = nil,
        endedAt: Date? = nil
    ) -> UUID {
        let step = AgentRunStep(
            runID: runID,
            sequence: currentRunSteps.count,
            kind: kind,
            status: status,
            title: title,
            detail: truncate(detail),
            toolName: toolName,
            endedAt: endedAt
        )
        currentRunSteps.append(step)
        historyService.saveStep(step)
        return step.id
    }

    private func updateStep(
        id: UUID,
        status: AgentRunStepStatus,
        detail: String? = nil,
        endedAt: Date? = nil
    ) {
        guard let index = currentRunSteps.firstIndex(where: { $0.id == id }) else { return }
        currentRunSteps[index].status = status
        if let detail {
            currentRunSteps[index].detail = truncate(detail)
        }
        currentRunSteps[index].endedAt = endedAt
        historyService.saveStep(currentRunSteps[index])
    }

    private func markOpenSteps(status: AgentRunStepStatus, detail: String) {
        for index in currentRunSteps.indices where !currentRunSteps[index].status.isFinished {
            currentRunSteps[index].status = status
            currentRunSteps[index].detail = truncate(detail)
            currentRunSteps[index].endedAt = Date()
            historyService.saveStep(currentRunSteps[index])
        }
    }

    private func finishCancelledRun(runID: UUID) {
        guard currentRun?.id == runID else { return }
        markOpenSteps(status: .cancelled, detail: "用户已停止运行")
        transitionCurrentRun(
            to: .cancelled,
            error: "用户停止运行",
            expectedRunID: runID
        )
        state = .idle
        currentStreamingContent = ""
        currentStreamingReasoning = ""
        currentToolCallName = nil
    }

    private func completeApprovalStep(detail: String) {
        guard let approval = currentRunSteps.last(where: {
            $0.kind == .approval && $0.status == .waiting
        }) else { return }
        updateStep(
            id: approval.id,
            status: .completed,
            detail: detail,
            endedAt: Date()
        )
    }

    private func refreshFileConversationCount() {
        guard let currentFilePath else {
            fileConversationCount = 0
            return
        }
        fileConversationCount = historyService.list(forFilePath: currentFilePath).count
    }

    // MARK: - Human-readable Summaries

    private func projectRootPath(for filePath: String) -> String? {
        ProjectManager.shared.listProjects()
            .first(where: {
                filePath == $0.url.path || filePath.hasPrefix($0.url.path + "/")
            })?
            .url.path
    }

    private func contextDetail(
        userText: String,
        documentText: String,
        referencedFiles: [ReferencedFile],
        selectedSnippets: [SelectedTextSnippet]
    ) -> String {
        let resolution = AIContextResolver.resolve(
            userText: userText,
            currentFilePath: currentFilePath,
            referencedFiles: referencedFiles
        )
        let referenceDetails = referencedFiles.isEmpty
            ? "无"
            : referencedFiles.map {
                "\(($0.path as NSString).lastPathComponent)（\($0.contentPreview.count) 字符）"
            }.joined(separator: "\n- ")
        let currentDocumentName = currentFilePath
            .map { ($0 as NSString).lastPathComponent }
            ?? "未命名文档"
        return """
        本轮主要目标：\(resolution.focus.displayName)
        目标选择依据：\(resolution.explanation)

        当前编辑文档：
        - \(currentDocumentName)（\(documentText.count) 字符）

        用户附加文件：
        - \(referenceDetails)

        编辑器选中片段：\(selectedSnippets.count) 个
        """
    }

    private func responseStructureDetail(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        let headings = lines.filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }.count
        let listItems = lines.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("- ")
                || trimmed.hasPrefix("* ")
                || trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
        }.count
        let paragraphs = content
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        return "\(headings) 个标题 · \(listItems) 个列表项 · \(paragraphs) 个内容块"
    }

    private func toolDisplayName(_ name: String) -> String {
        switch name {
        case "read_file", "read_project_file": return "读取本地文件"
        case "list_directory", "list_project_files": return "浏览项目文件"
        case "query_project_documents": return "检索项目文档"
        case "search_in_document": return "搜索当前文档"
        case "apply_markdown_edit", "apply_text_edit": return "生成文档修改建议"
        case "web_search": return "搜索网络资料"
        case "web_read": return "读取网页"
        case "query_user_memory", "search_file_index": return "查询本地记忆"
        case "record_memory": return "记录用户偏好"
        default: return "调用工具：\(name)"
        }
    }

    private func summarizeToolArguments(name: String, arguments: String) -> String {
        if name == "apply_markdown_edit" || name == "apply_text_edit" {
            return "准备一份需用户确认的完整文档修改建议"
        }
        guard
            let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return truncate(arguments.isEmpty ? "无参数" : arguments)
        }
        let safePairs = object.keys.sorted().prefix(4).map { key -> String in
            let value = String(describing: object[key] ?? "")
            return "\(key)：\(String(value.prefix(400)))"
        }
        return truncate("工具输入：\n" + safePairs.joined(separator: "\n"))
    }

    private func summarizeToolResult(_ result: ToolResult) -> String {
        let prefix = result.isError ? "执行失败" : "执行完成"
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return truncate(
            output.isEmpty
                ? prefix
                : "\(prefix)\n\n工具输出：\n\(output)"
        )
    }

    private func truncate(_ text: String) -> String {
        guard text.count > AgentRuntimePolicy.maximumVisibleDetailLength else { return text }
        return String(text.prefix(AgentRuntimePolicy.maximumVisibleDetailLength)) + "…"
    }
}

private enum AgentRuntimeError: LocalizedError {
    case modelRoundLimitExceeded(Int)
    case toolLimitExceeded(Int)

    var errorDescription: String? {
        switch self {
        case .modelRoundLimitExceeded(let limit):
            return "Agent 已达到 \(limit) 轮模型调用上限，运行已安全停止。"
        case .toolLimitExceeded(let limit):
            return "Agent 已达到 \(limit) 次工具调用上限，运行已安全停止。"
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
    return (
        String(normalized[..<range.lowerBound]),
        String(normalized[range.lowerBound...])
    )
}

private func parseDSMLToolCalls(from content: String) -> [DSMLToolCall]? {
    let normalized = normalizeDSML(content)
    let marker = "<||DSML||tool_calls>"
    guard normalized.contains(marker) else { return nil }

    let invokePattern = #"<\|\|DSML\|\|invoke\s+name="([^"]*)">"#
    let parameterPattern = #"<\|\|DSML\|\|parameter\s+name="([^"]*)"(?:\s+[^>]*)?>"#
    guard
        let invokeRegex = try? NSRegularExpression(pattern: invokePattern),
        let parameterRegex = try? NSRegularExpression(pattern: parameterPattern)
    else { return nil }

    let range = NSRange(normalized.startIndex..., in: normalized)
    let invokeMatches = invokeRegex.matches(in: normalized, range: range)
    guard !invokeMatches.isEmpty else { return nil }

    var calls: [DSMLToolCall] = []
    for (index, invokeMatch) in invokeMatches.enumerated() {
        guard let nameRange = Range(invokeMatch.range(at: 1), in: normalized) else { continue }
        let name = String(normalized[nameRange])
        let segmentStart = invokeMatch.range(at: 0).upperBound
        let segmentEnd = index + 1 < invokeMatches.count
            ? invokeMatches[index + 1].range(at: 0).location
            : normalized.utf16.count
        guard
            segmentEnd > segmentStart,
            let segmentRange = Range(
                NSRange(location: segmentStart, length: segmentEnd - segmentStart),
                in: normalized
            )
        else { continue }
        let segment = String(normalized[segmentRange])
        let parameterMatches = parameterRegex.matches(
            in: segment,
            range: NSRange(segment.startIndex..., in: segment)
        )

        var arguments: [String: String] = [:]
        for (parameterIndex, parameterMatch) in parameterMatches.enumerated() {
            guard let parameterNameRange = Range(parameterMatch.range(at: 1), in: segment) else {
                continue
            }
            let parameterName = String(segment[parameterNameRange])
            let valueStart = parameterMatch.range(at: 0).upperBound
            let valueEnd = parameterIndex + 1 < parameterMatches.count
                ? parameterMatches[parameterIndex + 1].range(at: 0).location
                : segment.utf16.count
            guard
                valueEnd > valueStart,
                let valueRange = Range(
                    NSRange(location: valueStart, length: valueEnd - valueStart),
                    in: segment
                )
            else { continue }
            var value = String(segment[valueRange])
            if let closeRange = value.range(of: "</||DSML||parameter>") {
                value = String(value[..<closeRange.lowerBound])
            }
            arguments[parameterName] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        calls.append(DSMLToolCall(name: name, arguments: arguments))
    }
    return calls.isEmpty ? nil : calls
}

private struct StreamingToolCallAccumulator {
    let id: String
    var name: String
    var arguments = ""
}
