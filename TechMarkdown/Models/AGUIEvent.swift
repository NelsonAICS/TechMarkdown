import Foundation

/// AG-UI (Agent-User Interaction Protocol) 事件类型
/// 参考: https://github.com/ag-ui-protocol/ag-ui
/// AG-UI 是一个开放的、轻量级、事件驱动、双向的 Agent-UI 通信协议。
enum AGUIEventType: String, CaseIterable, Identifiable {
    // Lifecycle
    case runStarted = "RUN_STARTED"
    case runFinished = "RUN_FINISHED"
    case runError = "RUN_ERROR"
    case stepStarted = "STEP_STARTED"
    case stepFinished = "STEP_FINISHED"
    
    // Text message
    case textMessageStart = "TEXT_MESSAGE_START"
    case textMessageContent = "TEXT_MESSAGE_CONTENT"
    case textMessageEnd = "TEXT_MESSAGE_END"
    case textMessageChunk = "TEXT_MESSAGE_CHUNK"
    
    // Tool call
    case toolCallStart = "TOOL_CALL_START"
    case toolCallArgs = "TOOL_CALL_ARGS"
    case toolCallEnd = "TOOL_CALL_END"
    case toolCallResult = "TOOL_CALL_RESULT"
    case toolCallChunk = "TOOL_CALL_CHUNK"
    
    // State
    case stateSnapshot = "STATE_SNAPSHOT"
    case stateDelta = "STATE_DELTA"
    case messagesSnapshot = "MESSAGES_SNAPSHOT"
    
    // Activity
    case activitySnapshot = "ACTIVITY_SNAPSHOT"
    case activityDelta = "ACTIVITY_DELTA"
    
    // Reasoning
    case reasoningStart = "REASONING_START"
    case reasoningMessageStart = "REASONING_MESSAGE_START"
    case reasoningMessageContent = "REASONING_MESSAGE_CONTENT"
    case reasoningMessageEnd = "REASONING_MESSAGE_END"
    case reasoningEnd = "REASONING_END"
    
    // Special
    case raw = "RAW"
    case custom = "CUSTOM"
    
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .runStarted: return "运行开始"
        case .runFinished: return "运行结束"
        case .runError: return "运行错误"
        case .stepStarted: return "步骤开始"
        case .stepFinished: return "步骤结束"
        case .textMessageStart: return "消息开始"
        case .textMessageContent: return "消息片段"
        case .textMessageEnd: return "消息结束"
        case .textMessageChunk: return "消息块"
        case .toolCallStart: return "工具调用开始"
        case .toolCallArgs: return "工具参数"
        case .toolCallEnd: return "工具调用结束"
        case .toolCallResult: return "工具结果"
        case .toolCallChunk: return "工具调用块"
        case .stateSnapshot: return "状态快照"
        case .stateDelta: return "状态变更"
        case .messagesSnapshot: return "消息快照"
        case .activitySnapshot: return "活动快照"
        case .activityDelta: return "活动变更"
        case .reasoningStart: return "推理开始"
        case .reasoningMessageStart: return "推理消息开始"
        case .reasoningMessageContent: return "推理消息片段"
        case .reasoningMessageEnd: return "推理消息结束"
        case .reasoningEnd: return "推理结束"
        case .raw: return "原始事件"
        case .custom: return "自定义"
        }
    }
}

/// AG-UI 事件统一结构
struct AGUIEvent: Identifiable {
    let id: UUID
    let type: AGUIEventType
    let timestamp: Date
    let threadId: String?
    let runId: String?
    let parentRunId: String?
    let messageId: String?
    let toolCallId: String?
    let payload: AGUIEventPayload
    
    init(
        id: UUID = UUID(),
        type: AGUIEventType,
        timestamp: Date = Date(),
        threadId: String? = nil,
        runId: String? = nil,
        parentRunId: String? = nil,
        messageId: String? = nil,
        toolCallId: String? = nil,
        payload: AGUIEventPayload
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.threadId = threadId
        self.runId = runId
        self.parentRunId = parentRunId
        self.messageId = messageId
        self.toolCallId = toolCallId
        self.payload = payload
    }
}

/// AG-UI 事件载荷协议
protocol AGUIEventPayload {
    var summary: String { get }
}

// MARK: - Lifecycle Events

struct RunStartedPayload: AGUIEventPayload {
    let runId: String
    let threadId: String
    let parentRunId: String?
    var summary: String { "运行开始: \(runId)" }
}

struct RunFinishedPayload: AGUIEventPayload {
    let runId: String
    let threadId: String
    var summary: String { "运行结束: \(runId)" }
}

struct RunErrorPayload: AGUIEventPayload {
    let runId: String
    let message: String
    let code: String?
    var summary: String { "运行错误: \(message)" }
}

struct StepStartedPayload: AGUIEventPayload {
    let stepName: String
    var summary: String { "步骤开始: \(stepName)" }
}

struct StepFinishedPayload: AGUIEventPayload {
    let stepName: String
    var summary: String { "步骤结束: \(stepName)" }
}

// MARK: - Text Message Events

struct TextMessageStartPayload: AGUIEventPayload {
    let messageId: String
    let role: String
    var summary: String { "开始生成 \(role) 消息" }
}

struct TextMessageContentPayload: AGUIEventPayload {
    let messageId: String
    let delta: String
    var summary: String { delta }
}

struct TextMessageEndPayload: AGUIEventPayload {
    let messageId: String
    let content: String
    var summary: String { "消息生成完成 (\(content.count) 字符)" }
}

struct TextMessageChunkPayload: AGUIEventPayload {
    let messageId: String?
    let role: String?
    let delta: String?
    var summary: String { delta ?? "消息块" }
}

// MARK: - Tool Call Events

struct ToolCallStartPayload: AGUIEventPayload {
    let toolCallId: String
    let toolCallName: String
    let parentMessageId: String?
    var summary: String { "调用工具: \(toolCallName)" }
}

struct ToolCallArgsPayload: AGUIEventPayload {
    let toolCallId: String
    let delta: String
    var summary: String { "参数更新" }
}

struct ToolCallEndPayload: AGUIEventPayload {
    let toolCallId: String
    var summary: String { "工具调用结束" }
}

struct ToolCallResultPayload: AGUIEventPayload {
    let messageId: String
    let toolCallId: String
    let content: String
    let role: String
    let error: String?
    var summary: String { error != nil ? "工具错误: \(error!)" : "工具返回 (\(content.count) 字符)" }
}

struct ToolCallChunkPayload: AGUIEventPayload {
    let toolCallId: String?
    let toolCallName: String?
    let parentMessageId: String?
    let delta: String?
    var summary: String { "工具调用块" }
}

// MARK: - State Events

struct StateSnapshotPayload: AGUIEventPayload {
    let snapshot: [String: String]
    var summary: String { "状态快照" }
}

struct StateDeltaPayload: AGUIEventPayload {
    let patch: [StatePatchOperation]
    var summary: String { "状态变更: \(patch.map(\.op).joined(separator: ", "))" }
}

struct StatePatchOperation: Codable {
    let op: String
    let path: String
    let value: String?
}

struct MessagesSnapshotPayload: AGUIEventPayload {
    let messages: [String]
    var summary: String { "消息快照 (\(messages.count) 条)" }
}

// MARK: - Activity Events

struct ActivitySnapshotPayload: AGUIEventPayload {
    let messageId: String
    let activityType: String
    let content: String
    var summary: String { "活动 [\(activityType)]" }
}

struct ActivityDeltaPayload: AGUIEventPayload {
    let messageId: String
    let activityType: String
    let patch: [StatePatchOperation]
    var summary: String { "活动更新 [\(activityType)]" }
}

// MARK: - Reasoning Events

struct ReasoningStartPayload: AGUIEventPayload {
    let messageId: String
    var summary: String { "推理开始" }
}

struct ReasoningMessageStartPayload: AGUIEventPayload {
    let messageId: String
    let role: String
    var summary: String { "推理消息开始" }
}

struct ReasoningMessageContentPayload: AGUIEventPayload {
    let messageId: String
    let delta: String
    var summary: String { delta }
}

struct ReasoningMessageEndPayload: AGUIEventPayload {
    let messageId: String
    var summary: String { "推理消息结束" }
}

struct ReasoningEndPayload: AGUIEventPayload {
    let messageId: String
    var summary: String { "推理结束" }
}

// MARK: - Special Events

struct RawPayload: AGUIEventPayload {
    let event: String
    let source: String?
    var summary: String { "原始事件 (\(source ?? "unknown"))" }
}

struct CustomPayload: AGUIEventPayload {
    let name: String
    let value: String
    var summary: String { "自定义: \(name)" }
}
