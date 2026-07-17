import Foundation
import CryptoKit

/// 一次 Agent 运行的持久化生命周期。
enum AgentRunStatus: String, Codable, CaseIterable {
    case preparing
    case retrieving
    case generating
    case executingTool
    case awaitingApproval
    case finalizing
    case completed
    case failed
    case cancelled
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        default:
            return false
        }
    }

    var isRecoverable: Bool {
        self == .failed || self == .interrupted
    }

    var displayName: String {
        switch self {
        case .preparing: return "准备运行"
        case .retrieving: return "组织上下文"
        case .generating: return "生成回答"
        case .executingTool: return "执行工具"
        case .awaitingApproval: return "等待确认"
        case .finalizing: return "保存结果"
        case .completed: return "已完成"
        case .failed: return "运行失败"
        case .cancelled: return "已停止"
        case .interrupted: return "意外中断"
        }
    }
}

enum AgentRunStepKind: String, Codable {
    case context
    case intent
    case reasoningSummary
    case generation
    case toolCall
    case toolResult
    case approval
    case persistence
    case error
}

enum AgentRunStepStatus: String, Codable {
    case pending
    case running
    case waiting
    case completed
    case failed
    case cancelled

    var isFinished: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

/// UI 可重放的语义步骤。原始 token 不进入该模型。
struct AgentRunStep: Identifiable, Codable, Equatable {
    let id: UUID
    let runID: UUID
    var sequence: Int
    var kind: AgentRunStepKind
    var status: AgentRunStepStatus
    var title: String
    var detail: String
    var toolName: String?
    var startedAt: Date
    var endedAt: Date?

    init(
        id: UUID = UUID(),
        runID: UUID,
        sequence: Int,
        kind: AgentRunStepKind,
        status: AgentRunStepStatus = .running,
        title: String,
        detail: String = "",
        toolName: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.sequence = sequence
        self.kind = kind
        self.status = status
        self.title = title
        self.detail = detail
        self.toolName = toolName
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    var isExpandedByDefault: Bool {
        switch status {
        case .running, .waiting, .failed:
            return true
        case .pending, .completed, .cancelled:
            return false
        }
    }

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

struct AgentRunRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let conversationID: UUID
    let threadID: String
    var parentRunID: UUID?
    var status: AgentRunStatus
    var checkpointMessageCount: Int
    var modelRoundCount: Int
    var toolCallCount: Int
    var startedAt: Date
    var updatedAt: Date
    var endedAt: Date?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        threadID: String,
        parentRunID: UUID? = nil,
        status: AgentRunStatus = .preparing,
        checkpointMessageCount: Int,
        modelRoundCount: Int = 0,
        toolCallCount: Int = 0,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        endedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.threadID = threadID
        self.parentRunID = parentRunID
        self.status = status
        self.checkpointMessageCount = checkpointMessageCount
        self.modelRoundCount = modelRoundCount
        self.toolCallCount = toolCallCount
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.errorMessage = errorMessage
    }

    mutating func transition(to newStatus: AgentRunStatus, error: String? = nil, at date: Date = Date()) {
        status = newStatus
        updatedAt = date
        errorMessage = error
        if newStatus.isTerminal {
            endedAt = date
        }
    }
}

struct ConversationContext: Codable, Equatable {
    var primaryFilePath: String?
    var projectRootPath: String?
    var referencedFiles: [ReferencedFile]
    var documentFingerprint: String?
    var pendingEdit: PendingEdit?

    init(
        primaryFilePath: String? = nil,
        projectRootPath: String? = nil,
        referencedFiles: [ReferencedFile] = [],
        documentFingerprint: String? = nil,
        pendingEdit: PendingEdit? = nil
    ) {
        self.primaryFilePath = primaryFilePath
        self.projectRootPath = projectRootPath
        self.referencedFiles = referencedFiles
        self.documentFingerprint = documentFingerprint
        self.pendingEdit = pendingEdit
    }
}

enum ContentFingerprint {
    static func make(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum AgentRuntimePolicy {
    static let maximumModelRounds = 8
    static let maximumToolCalls = 12
    static let maximumVisibleDetailLength = 2_400
}

enum AIContextFocus: String, Codable, Equatable {
    case currentDocument
    case referencedFiles
    case combined

    var displayName: String {
        switch self {
        case .currentDocument: return "分析当前编辑文档"
        case .referencedFiles: return "分析用户附加文件"
        case .combined: return "联合分析当前文档与附件"
        }
    }
}

struct AIContextResolution: Equatable {
    let focus: AIContextFocus
    let primarySourceNames: [String]
    let explanation: String

    var promptInstruction: String {
        let sources = primarySourceNames.isEmpty
            ? "当前编辑文档"
            : primarySourceNames.joined(separator: "、")
        switch focus {
        case .currentDocument:
            return """
            本轮主要分析对象是当前编辑文档。引用文件仅作为补充资料。
            回答开头用 Markdown 引用行注明：分析对象：当前编辑文档。
            """
        case .referencedFiles:
            return """
            本轮主要分析对象是用户主动附加的文件：\(sources)。
            不要把当前编辑文档当作本轮总结对象，也不要用它替代附件内容。
            回答开头用 Markdown 引用行注明：分析对象：\(sources)。
            """
        case .combined:
            return """
            本轮需要联合分析当前编辑文档与这些附件：\(sources)。
            回答中明确区分不同文件的事实，不能把内容混为一份文档。
            回答开头用 Markdown 引用行注明：分析对象：当前编辑文档 + \(sources)。
            """
        }
    }
}

enum AIContextResolver {
    static func resolve(
        userText: String,
        currentFilePath: String?,
        referencedFiles: [ReferencedFile]
    ) -> AIContextResolution {
        let included = referencedFiles.filter(\.isIncluded)
        let names = included.map { ($0.path as NSString).lastPathComponent }
        guard !included.isEmpty else {
            return AIContextResolution(
                focus: .currentDocument,
                primarySourceNames: currentFilePath.map { [($0 as NSString).lastPathComponent] } ?? [],
                explanation: "本轮没有附加文件，使用当前编辑文档"
            )
        }

        let lower = userText.lowercased()
        let combinedTerms = [
            "一起", "结合", "对比", "比较", "综合", "参考附件",
            "两份", "这些文件", "所有文件", "current and"
        ]
        if combinedTerms.contains(where: { lower.contains($0) }) {
            return AIContextResolution(
                focus: .combined,
                primarySourceNames: names,
                explanation: "用户要求联合处理当前文档和附件"
            )
        }

        let explicitCurrentTerms = [
            "当前文档", "正在编辑的文档", "当前文件", "本文",
            "编辑器里的文档", "active document", "current document"
        ]
        if explicitCurrentTerms.contains(where: { lower.contains($0) }) {
            return AIContextResolution(
                focus: .currentDocument,
                primarySourceNames: currentFilePath.map { [($0 as NSString).lastPathComponent] } ?? [],
                explanation: "用户明确指定当前编辑文档"
            )
        }

        return AIContextResolution(
            focus: .referencedFiles,
            primarySourceNames: names,
            explanation: "用户已主动附加文件，附件默认成为本轮主要分析对象"
        )
    }
}

enum AgentRecoveryPlanner {
    /// 仅返回没有工具回执的调用；已有回执意味着副作用已经完成，恢复时不能重放。
    static func unresolvedToolCalls(in messages: [ChatMessage]) -> [ToolCall] {
        let completedCallIDs = Set(
            messages
                .filter { $0.role == .tool }
                .compactMap(\.toolCallID)
        )
        return messages
            .filter { $0.role == .assistant }
            .flatMap { $0.toolCalls ?? [] }
            .filter { !completedCallIDs.contains($0.id) }
    }
}
