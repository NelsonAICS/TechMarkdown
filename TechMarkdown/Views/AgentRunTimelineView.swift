import SwiftUI

/// 将持久化的 Agent 语义步骤呈现为可检查、可折叠的时间线。
struct AgentRunTimelineView: View {
    let run: AgentRunRecord
    let steps: [AgentRunStep]
    @Bindable var themeManager: ThemeManager
    var onStop: (() -> Void)?
    var onResume: (() -> Void)?

    @State private var isExpanded: Bool

    init(
        run: AgentRunRecord,
        steps: [AgentRunStep],
        themeManager: ThemeManager,
        onStop: (() -> Void)? = nil,
        onResume: (() -> Void)? = nil
    ) {
        self.run = run
        self.steps = steps
        self.themeManager = themeManager
        self.onStop = onStop
        self.onResume = onResume
        _isExpanded = State(initialValue: !run.status.isTerminal || run.status.isRecoverable)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.status.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(themeManager.textPrimary)
                        Text(summary)
                            .font(.system(size: 10))
                            .foregroundStyle(themeManager.textMuted)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(themeManager.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(11)

            if isExpanded {
                Divider().overlay(themeManager.border)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: "cursorarrow.click")
                        Text("点击任一步骤查看资料、判断依据和实际结果")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(themeManager.textMuted)
                    .padding(.horizontal, 11)
                    .padding(.top, 9)
                    .padding(.bottom, 3)

                    ForEach(steps.sorted(by: { $0.sequence < $1.sequence })) { step in
                        AgentRunStepRow(step: step, themeManager: themeManager)
                    }

                    if steps.isEmpty {
                        Text("尚未记录步骤")
                            .font(.caption)
                            .foregroundStyle(themeManager.textMuted)
                            .padding(12)
                    }

                    if run.status.isRecoverable, let onResume {
                        Button(action: onResume) {
                            Label("从安全检查点恢复", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(10)
                    } else if !run.status.isTerminal, run.status != .awaitingApproval, let onStop {
                        Button(role: .destructive, action: onStop) {
                            Label("停止运行", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(10)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.45), lineWidth: 1)
        )
        .onChange(of: run.status) { _, newStatus in
            if newStatus.isRecoverable || newStatus == .awaitingApproval {
                isExpanded = true
            } else if newStatus == .completed {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded = false
                }
            }
        }
    }

    private var summary: String {
        var parts = ["\(steps.count) 个步骤"]
        if run.modelRoundCount > 0 {
            parts.append("\(run.modelRoundCount) 轮生成")
        }
        if run.toolCallCount > 0 {
            parts.append("\(run.toolCallCount) 次工具")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.14))
                .frame(width: 26, height: 26)
            if run.status == .generating || run.status == .executingTool {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusColor)
            } else {
                Image(systemName: statusSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var statusColor: Color {
        switch run.status {
        case .completed: return themeManager.success
        case .failed, .interrupted: return themeManager.error
        case .cancelled: return themeManager.textMuted
        case .awaitingApproval: return themeManager.warning
        default: return themeManager.accent
        }
    }

    private var statusSymbol: String {
        switch run.status {
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .interrupted: return "bolt.slash"
        case .cancelled: return "stop.fill"
        case .awaitingApproval: return "hand.raised.fill"
        default: return "sparkles"
        }
    }
}

private struct AgentRunStepRow: View {
    let step: AgentRunStep
    @Bindable var themeManager: ThemeManager
    @State private var isExpanded: Bool

    init(step: AgentRunStep, themeManager: ThemeManager) {
        self.step = step
        self.themeManager = themeManager
        _isExpanded = State(initialValue: step.isExpandedByDefault)
    }

    var body: some View {
        rowContent
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleDetail) {
                rowHeader
            }
            .buttonStyle(.plain)

            if isExpanded, !step.detail.isEmpty {
                detailText
            }
        }
    }

    private var rowHeader: some View {
        HStack(alignment: .top, spacing: 9) {
            stepMarker
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(themeManager.textPrimary)
                    .multilineTextAlignment(.leading)
                Text(metadata)
                    .font(.system(size: 9))
                    .foregroundStyle(themeManager.textMuted)
                if !step.detail.isEmpty, !isExpanded {
                    Text(detailPreview)
                        .font(.system(size: 9))
                        .foregroundStyle(themeManager.textSecondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 1)
                }
            }
            Spacer()
            if !step.detail.isEmpty {
                HStack(spacing: 4) {
                    Text(isExpanded ? "收起" : "详情")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(themeManager.accentSecondary)
                .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private var detailText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("可核验运行记录", systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(themeManager.accentSecondary)
            Text(step.detail)
                .font(.system(size: 10))
                .lineSpacing(3)
                .foregroundStyle(themeManager.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(themeManager.backgroundCode.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(themeManager.border, lineWidth: 1)
        )
        .padding(.leading, 34)
        .padding(.trailing, 11)
        .padding(.bottom, 9)
    }

    private var detailPreview: String {
        step.detail
            .replacingOccurrences(of: "\n", with: " · ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private var metadata: String {
        guard let duration = step.duration else {
            return step.status.displayName
        }
        return "\(step.status.displayName) · \(String(format: "%.1f", duration)) 秒"
    }

    private func toggleDetail() {
        guard !step.detail.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            isExpanded.toggle()
        }
    }

    @ViewBuilder
    private var stepMarker: some View {
        ZStack {
            Circle()
                .fill(markerColor.opacity(0.14))
                .frame(width: 16, height: 16)
            if step.status == .running {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .tint(markerColor)
            } else {
                Image(systemName: markerSymbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(markerColor)
            }
        }
    }

    private var markerColor: Color {
        switch step.status {
        case .completed: return themeManager.success
        case .failed: return themeManager.error
        case .waiting: return themeManager.warning
        case .cancelled: return themeManager.textMuted
        case .pending, .running: return themeManager.accent
        }
    }

    private var markerSymbol: String {
        switch step.status {
        case .completed: return "checkmark"
        case .failed: return "xmark"
        case .waiting: return "pause.fill"
        case .cancelled: return "stop.fill"
        case .pending: return "circle"
        case .running: return "circle"
        }
    }
}

private extension AgentRunStepStatus {
    var displayName: String {
        switch self {
        case .pending: return "等待"
        case .running: return "进行中"
        case .waiting: return "需要操作"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已停止"
        }
    }
}
