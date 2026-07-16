import Foundation
import Combine

/// AG-UI 本地事件总线
/// 负责收集一次 Agent Run 中产生的所有 AG-UI 事件，供 UI 订阅和渲染。
/// 在真实 AG-UI 架构中，这部分对应 Client 端的 EventStreamManager。
@Observable
final class AGUIEventBus {
    private(set) var events: [AGUIEvent] = []
    private(set) var currentThreadId: String?
    private(set) var currentRunId: String?
    private(set) var parentRunId: String?
    
    private let subject = PassthroughSubject<AGUIEvent, Never>()
    var publisher: AnyPublisher<AGUIEvent, Never> { subject.eraseToAnyPublisher() }
    
    func startRun(threadId: String, runId: String, parentRunId: String? = nil) {
        self.currentThreadId = threadId
        self.currentRunId = runId
        self.parentRunId = parentRunId
        emit(
            .runStarted,
            payload: RunStartedPayload(runId: runId, threadId: threadId, parentRunId: parentRunId)
        )
    }
    
    func finishRun() {
        guard let runId = currentRunId, let threadId = currentThreadId else { return }
        emit(
            .runFinished,
            payload: RunFinishedPayload(runId: runId, threadId: threadId)
        )
        currentRunId = nil
        parentRunId = nil
    }
    
    func error(_ message: String, code: String? = nil) {
        guard let runId = currentRunId else { return }
        emit(
            .runError,
            payload: RunErrorPayload(runId: runId, message: message, code: code)
        )
    }
    
    @discardableResult
    func emit(
        _ type: AGUIEventType,
        messageId: String? = nil,
        toolCallId: String? = nil,
        payload: AGUIEventPayload
    ) -> AGUIEvent {
        let event = AGUIEvent(
            type: type,
            threadId: currentThreadId,
            runId: currentRunId,
            parentRunId: parentRunId,
            messageId: messageId,
            toolCallId: toolCallId,
            payload: payload
        )
        events.append(event)
        subject.send(event)
        return event
    }
    
    /// 将外部已经构造好的 AG-UI 事件加入总线，用于流式解析事件的透传
    func relay(_ event: AGUIEvent) {
        events.append(event)
        subject.send(event)
    }
    
    func clear() {
        events.removeAll()
        currentThreadId = nil
        currentRunId = nil
        parentRunId = nil
    }
}
