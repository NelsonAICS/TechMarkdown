import SwiftUI
import AppKit

struct AISidebarView: View {
    @Bindable var agent: AIAgent
    @Binding var documentText: String
    @Bindable var themeManager: ThemeManager
    @EnvironmentObject var documentState: DocumentState

    @State private var inputText = ""
    @State private var showingSkillPicker = false
    @State private var showingFilePicker = false
    @State private var showEventLog = false
    @State private var showConversationHistory = false
    @State private var showSettings = false
    @State private var selectedWorkspace: SidebarWorkspace = .conversation
    @State private var annotationComposerDraft: AnnotationDraft?
    @State private var annotationComposerError: String?
    @State private var overlappingAnnotation: Annotation?
    @State private var annotations: [Annotation] = []
    @State private var annotationFilter: AnnotationFilter = .all
    @State private var selectedHunkIDs: Set<UUID> = []
    @FocusState private var annotationComposerFocused: Bool

    private var filteredAnnotations: [Annotation] {
        switch annotationFilter {
        case .all: return annotations
        case .unresolved: return annotations.filter { !$0.resolved }
        case .resolved: return annotations.filter { $0.resolved }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            workspacePicker

            switch selectedWorkspace {
            case .conversation:
                conversationWorkspace
            case .annotations:
                annotationWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.backgroundPrimary)
        .onAppear { refreshAnnotations() }
        .onChange(of: documentState.currentFileURL) { _, _ in
            annotationComposerDraft = nil
            annotationComposerError = nil
            refreshAnnotations()
        }
        .onReceive(NotificationCenter.default.publisher(for: .annotationListChanged)) { _ in
            refreshAnnotations()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAnnotationComposer)) { notification in
            guard let draft = notification.object as? AnnotationDraft else { return }
            selectedWorkspace = .annotations
            annotationComposerDraft = draft
            annotationComposerError = nil
            overlappingAnnotation = nil
            DispatchQueue.main.async {
                annotationComposerFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusAnnotation)) { _ in
            selectedWorkspace = .annotations
            refreshAnnotations()
        }
    }

    private var conversationWorkspace: some View {
        VStack(spacing: 0) {
            if showEventLog {
                AGUIEventLogView(
                    events: agent.eventBus.events,
                    themeManager: themeManager,
                    onClose: { showEventLog = false }
                )
                .frame(maxHeight: 220)
                .background(themeManager.backgroundSecondary)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(themeManager.border),
                    alignment: .bottom
                )
            }

            runtimeNotice
            messageList
                .background(themeManager.backgroundPrimary)

            referencedFilesSection
            pendingEditSection
            inputArea
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("AI 助手", systemImage: "brain.head.profile")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(themeManager.textPrimary)

            Spacer()

            if agent.isProcessing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(agent.state.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.accent)
                }
            }

            // 主要操作
            HeaderButton(icon: "square.and.pencil", help: "新建对话") {
                startNewConversation()
            }

            HeaderButton(icon: "clock.arrow.circlepath", help: "对话历史") {
                showConversationHistory.toggle()
            }
            .sheet(isPresented: $showConversationHistory) {
                ConversationHistoryView(
                    agent: agent,
                    themeManager: themeManager,
                    currentDocumentText: documentText
                )
                    .frame(minWidth: 460, minHeight: 540)
            }

            HeaderButton(icon: "gearshape", help: "AI 设置") {
                showSettings.toggle()
            }
            .foregroundColor(themeManager.accent)
            .sheet(isPresented: $showSettings) {
                AISettingsView(agent: agent)
                    .frame(minWidth: 640, minHeight: 560)
            }

            if agent.isProcessing {
                HeaderButton(icon: "xmark.octagon", help: "取消运行") {
                    agent.cancelRun()
                }
                .foregroundColor(themeManager.error)
            }

            // 次要操作：收起在“更多”菜单中，避免头部被挤到溢出
            Menu {
                Button {
                    showEventLog.toggle()
                } label: {
                    Label("AG-UI 事件流", systemImage: showEventLog ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                }

                Button {
                    showingSkillPicker.toggle()
                } label: {
                    Label("选择 Skill", systemImage: "wand.and.stars")
                }

                Button {
                    exportConversation()
                } label: {
                    Label("导出对话", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button(role: .destructive) {
                    agent.clearConversation()
                } label: {
                    Label("清空对话", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundColor(themeManager.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(themeManager.backgroundTertiary.opacity(0.4))
                    )
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .tint(themeManager.textSecondary)
            .help("更多操作")
            .popover(isPresented: $showingSkillPicker) {
                SkillPickerView(
                    agent: agent,
                    documentText: documentText,
                    isPresented: $showingSkillPicker,
                    themeManager: themeManager
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 44)
        .background(themeManager.backgroundSecondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(themeManager.border),
            alignment: .bottom
        )
    }

    private func startNewConversation() {
        agent.startNewConversation(documentText: documentText)
        inputText = ""
        selectedWorkspace = .conversation
        showEventLog = false
    }

    private var workspacePicker: some View {
        HStack(spacing: 4) {
            ForEach(SidebarWorkspace.allCases) { workspace in
                let isSelected = selectedWorkspace == workspace
                Button {
                    selectedWorkspace = workspace
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: workspace.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(workspace.title)
                            .font(.system(size: 11, weight: .semibold))

                        if workspace == .annotations, !annotations.isEmpty {
                            Text("\(annotations.filter { !$0.resolved }.count)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? themeManager.backgroundPrimary.opacity(0.22) : themeManager.backgroundTertiary)
                                )
                        }
                    }
                    .foregroundStyle(
                        isSelected
                            ? themeManager.controlSelectedForeground
                            : themeManager.textSecondary
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isSelected ? themeManager.controlSelectedBackground : Color.clear)
                    )
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(themeManager.controlSelectedBorder, lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(themeManager.backgroundSecondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(themeManager.border),
            alignment: .bottom
        )
    }

    // MARK: - Messages

    @ViewBuilder
    private var runtimeNotice: some View {
        if agent.recoverableRun != nil || agent.contextNotice != nil {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: agent.recoverableRun == nil ? "doc.text.magnifyingglass" : "arrow.clockwise.circle.fill")
                    .foregroundStyle(agent.recoverableRun == nil ? themeManager.accentSecondary : themeManager.warning)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.recoverableRun == nil ? "上下文已更新" : "上次运行可以恢复")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(themeManager.textPrimary)
                    Text(agent.contextNotice ?? "将从上次安全检查点继续，不会重复执行已完成的工具。")
                        .font(.system(size: 10))
                        .foregroundStyle(themeManager.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if agent.recoverableRun != nil {
                    Button("恢复") {
                        agent.resumeLastRun(documentText: documentText)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }
            .padding(10)
            .background(themeManager.backgroundSecondary)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(themeManager.border),
                alignment: .bottom
            )
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if agent.messages.isEmpty && agent.currentStreamingContent.isEmpty && !agent.isProcessing {
                        emptyState
                    }

                    ForEach(agent.messages.filter { $0.role != .tool }) { message in
                        MessageBubble(message: message, themeManager: themeManager)
                            .id(message.id)
                    }

                    if let run = agent.currentRun {
                        AgentRunTimelineView(
                            run: run,
                            steps: agent.currentRunSteps,
                            themeManager: themeManager,
                            onStop: { agent.cancelRun() },
                            onResume: {
                                agent.resumeLastRun(documentText: documentText)
                            }
                        )
                        .id(run.id)
                    }

                    if !agent.currentStreamingContent.isEmpty || !agent.currentStreamingReasoning.isEmpty {
                        StreamingMessageBubble(
                            content: agent.currentStreamingContent,
                            reasoning: agent.currentStreamingReasoning,
                            toolCallName: agent.currentToolCallName,
                            themeManager: themeManager
                        )
                        .id("streaming")
                    }

                    if agent.isProcessing && agent.currentStreamingContent.isEmpty && agent.currentStreamingReasoning.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(agent.state.displayName)
                                .font(.caption)
                                .foregroundColor(themeManager.textMuted)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(themeManager.backgroundTertiary)
                        .cornerRadius(10)
                        .id("typing")
                    }
                }
                .padding()
            }
            .onChange(of: agent.messages.count) { _, _ in
                if let last = agent.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: agent.currentStreamingContent) { _, _ in
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 40))
                .foregroundColor(themeManager.textMuted.opacity(0.5))
            Text("AI 助手已就绪")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(themeManager.textSecondary)
            Text("在下方输入框提问，或选择 Skill 快速处理文档。")
                .font(.caption)
                .foregroundColor(themeManager.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Referenced Files

    private var referencedFilesSection: some View {
        Group {
            if !agent.referencedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已选资料")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(themeManager.textSecondary)
                            Text("发送时优先作为本轮分析对象")
                                .font(.system(size: 9))
                                .foregroundColor(themeManager.textMuted)
                        }
                        Spacer()
                        Text("\(agent.referencedFiles.filter(\.isIncluded).count)/\(agent.referencedFiles.count)")
                            .font(.caption2)
                            .foregroundColor(themeManager.textMuted)
                    }
                    .padding(.horizontal, 14)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(agent.referencedFiles) { file in
                                ReferencedFileChip(
                                    file: file,
                                    agent: agent,
                                    themeManager: themeManager
                                )
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 10)
                .background(themeManager.backgroundSecondary)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(themeManager.border),
                    alignment: .top
                )
            }
        }
    }

    // MARK: - Annotation workspace

    @ViewBuilder
    private var annotationWorkspace: some View {
        if let path = documentState.currentFileURL?.path {
            VStack(spacing: 0) {
                annotationToolbar

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if annotationComposerDraft != nil {
                            annotationComposer(path: path)
                        }

                        if annotations.isEmpty, annotationComposerDraft == nil {
                            annotationEmptyState
                        } else if filteredAnnotations.isEmpty {
                            Text("当前筛选条件下没有批注")
                                .font(.system(size: 11))
                                .foregroundStyle(themeManager.textMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 34)
                        } else {
                            ForEach(filteredAnnotations) { annotation in
                                AnnotationRow(
                                    annotation: annotation,
                                    path: path,
                                    documentText: documentText,
                                    onChange: refreshAnnotations,
                                    themeManager: themeManager
                                )
                            }
                        }
                    }
                    .padding(12)
                }

                annotationFooter(path: path)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(themeManager.textMuted)
                Text("请先保存文档")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(themeManager.textSecondary)
                Text("批注需要与本地文件关联，保存后即可开始审阅。")
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        }
    }

    private var annotationToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("审阅意见")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(themeManager.textPrimary)
                    Text("\(annotations.filter { !$0.resolved }.count) 条待处理")
                        .font(.system(size: 10))
                        .foregroundStyle(themeManager.textMuted)
                }

                Spacer()

                Button {
                    beginDocumentAnnotation()
                } label: {
                    Label("全文意见", systemImage: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(themeManager.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(themeManager.accent.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .help("添加不绑定具体选区的文档级意见")
            }

            HStack(spacing: 5) {
                annotationFilterButton(.unresolved, title: "待处理", count: annotations.filter { !$0.resolved }.count)
                annotationFilterButton(.resolved, title: "已解决", count: annotations.filter(\.resolved).count)
                annotationFilterButton(.all, title: "全部", count: annotations.count)
            }
        }
        .padding(12)
        .background(themeManager.backgroundSecondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(themeManager.border),
            alignment: .bottom
        )
    }

    private func annotationFilterButton(
        _ filter: AnnotationFilter,
        title: String,
        count: Int
    ) -> some View {
        let selected = annotationFilter == filter
        return Button {
            annotationFilter = filter
        } label: {
            Text("\(title) \(count)")
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? themeManager.textPrimary : themeManager.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? themeManager.backgroundTertiary : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? themeManager.border : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func annotationComposer(path: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: annotationComposerDraft?.isAnchored == true ? "selection.pin.in.out" : "doc.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                Text(annotationComposerDraft?.isAnchored == true ? "针对选中文本" : "全文意见")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(themeManager.textPrimary)
                Spacer()
                Button {
                    cancelAnnotationComposer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(themeManager.textMuted)
                }
                .buttonStyle(.plain)
                .help("取消")
            }

            if let draft = annotationComposerDraft, draft.isAnchored {
                Text(draft.selectedText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(themeManager.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(themeManager.annotationHighlight.opacity(0.10))
                    )
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(themeManager.annotationHighlight)
                            .frame(width: 2)
                    }
            }

            TextEditor(text: annotationDraftBinding)
                .font(.system(size: 12))
                .foregroundStyle(themeManager.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: 120)
                .padding(7)
                .background(themeManager.backgroundPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(themeManager.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .focused($annotationComposerFocused)

            if let error = annotationComposerError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error)
                    Spacer()
                    if overlappingAnnotation != nil {
                        Button("查看") {
                            showOverlappingAnnotation()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(themeManager.accent)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(themeManager.warning)
            }

            HStack {
                Text(annotationComposerDraft?.source == .preview ? "来自预览" : "来自编辑器")
                    .font(.system(size: 9))
                    .foregroundStyle(themeManager.textMuted)
                    .opacity(annotationComposerDraft?.isAnchored == true ? 1 : 0)

                Spacer()

                Button("取消") {
                    cancelAnnotationComposer()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(themeManager.textMuted)

                Button("添加批注") {
                    saveAnnotationDraft(path: path)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    annotationDraftBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? themeManager.textMuted
                        : themeManager.accent
                )
                .disabled(annotationDraftBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(11)
        .background(themeManager.backgroundSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(themeManager.accent.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var annotationEmptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(themeManager.accent)

            Text("还没有审阅意见")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(themeManager.textPrimary)

            Text("在编辑器或预览中选中文字并右键，选择“添加批注”。")
                .font(.system(size: 11))
                .foregroundStyle(themeManager.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 46)
    }

    private func annotationFooter(path: String) -> some View {
        let unresolvedCount = annotations.filter { !$0.resolved }.count
        return Button {
            optimizeBasedOnAnnotations(path: path)
            selectedWorkspace = .conversation
        } label: {
            HStack {
                Image(systemName: "sparkles")
                Text(unresolvedCount == 0 ? "没有待处理意见" : "让 AI 根据 \(unresolvedCount) 条意见优化")
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(unresolvedCount == 0 ? themeManager.textMuted : themeManager.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(themeManager.backgroundSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unresolvedCount == 0)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(themeManager.border),
            alignment: .top
        )
    }

    private func refreshAnnotations() {
        annotations = AnnotationService.shared.annotations(for: documentState.currentFileURL?.path)
    }

    private var annotationDraftBinding: Binding<String> {
        Binding(
            get: { annotationComposerDraft?.text ?? "" },
            set: { value in
                guard var draft = annotationComposerDraft else { return }
                draft.text = value
                annotationComposerDraft = draft
                annotationComposerError = nil
                overlappingAnnotation = nil
            }
        )
    }

    private func beginDocumentAnnotation() {
        annotationComposerDraft = AnnotationDraft(
            selectedText: "",
            context: "",
            rangeSnapshot: nil,
            source: .document
        )
        annotationComposerError = nil
        overlappingAnnotation = nil
        DispatchQueue.main.async {
            annotationComposerFocused = true
        }
    }

    private func cancelAnnotationComposer() {
        annotationComposerDraft = nil
        annotationComposerError = nil
        overlappingAnnotation = nil
    }

    private func saveAnnotationDraft(path: String) {
        guard let draft = annotationComposerDraft else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if draft.isAnchored,
           let overlap = AnnotationService.shared.existingOverlappingAnnotation(
               selectedText: draft.selectedText,
               context: draft.context,
               rangeSnapshot: draft.rangeSnapshot,
               for: path
           ) {
            overlappingAnnotation = overlap
            annotationComposerError = "该选区已有一条待处理批注，请先处理或编辑现有批注。"
            return
        }

        guard AnnotationService.shared.addAnnotation(
            text,
            selectedText: draft.selectedText,
            context: draft.context,
            rangeSnapshot: draft.rangeSnapshot,
            for: path
        ) != nil else {
            annotationComposerError = "批注未能保存，请确认文档已保存到本地。"
            return
        }

        cancelAnnotationComposer()
        annotationFilter = .unresolved
        refreshAnnotations()
    }

    private func showOverlappingAnnotation() {
        guard let overlappingAnnotation else { return }
        NotificationCenter.default.post(name: .scrollEditorToAnnotation, object: overlappingAnnotation)
        NotificationCenter.default.post(name: .scrollPreviewToAnnotation, object: overlappingAnnotation)
        cancelAnnotationComposer()
    }

    private func optimizeBasedOnAnnotations(path: String) {
        let list = annotations.filter { !$0.resolved }
        guard !list.isEmpty else { return }
        let prompt = list
            .enumerated()
            .map { index, ann -> String in
                var line = "\(index + 1). \(ann.text)"
                if !ann.selectedText.isEmpty {
                    line += "\n   针对文本：「\(ann.selectedText)」"
                }
                return line
            }
            .joined(separator: "\n\n")
        agent.sendMessage("请根据以下批注优化当前文档内容（每条批注已附带对应的原文位置）：\n\n\(prompt)", documentText: documentText)
    }

    enum AnnotationFilter: String, CaseIterable, Identifiable {
        case all, unresolved, resolved
        var id: String { rawValue }
    }

    enum SidebarWorkspace: String, CaseIterable, Identifiable {
        case conversation
        case annotations

        var id: String { rawValue }
        var title: String {
            switch self {
            case .conversation: return "对话"
            case .annotations: return "批注"
            }
        }
        var icon: String {
            switch self {
            case .conversation: return "bubble.left.and.bubble.right"
            case .annotations: return "text.badge.checkmark"
            }
        }
    }

    // MARK: - Pending Edit

    private var pendingEditSection: some View {
        Group {
            if let edit = agent.pendingEdit {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil.line")
                            .foregroundColor(themeManager.warning)
                        Text("AI 修改建议")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(themeManager.textPrimary)
                        Spacer()
                    }

                    Text(edit.reason)
                        .font(.caption)
                        .foregroundColor(themeManager.textSecondary)
                        .lineLimit(2)

                    if edit.hunks.isEmpty {
                        DiffSummaryView(originalText: edit.originalText, suggestedText: edit.suggestedText, themeManager: themeManager)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(edit.hunks) { hunk in
                                    HunkRow(
                                        hunk: hunk,
                                        isSelected: selectedHunkIDs.contains(hunk.id),
                                        themeManager: themeManager,
                                        onToggle: { isOn in
                                            if isOn {
                                                selectedHunkIDs.insert(hunk.id)
                                            } else {
                                                selectedHunkIDs.remove(hunk.id)
                                            }
                                        }
                                    )
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }

                    HStack(spacing: 12) {
                        Button("查看差异") {
                            NotificationCenter.default.post(name: .showPendingEditDiff, object: edit)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(themeManager.accent)

                        Spacer()

                        Button("全部放弃") {
                            selectedHunkIDs.removeAll()
                            agent.discardPendingEdit()
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(themeManager.textMuted)

                        Button("应用选中") {
                            agent.applySelectedHunks(selectedHunkIDs, to: &documentText)
                            selectedHunkIDs.removeAll()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedHunkIDs.isEmpty)
                    }
                }
                .padding()
                .background(themeManager.warning.opacity(0.08))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(themeManager.warning.opacity(0.25), lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .onAppear {
                    selectedHunkIDs = Set(edit.hunks.map(\.id))
                }
            }
        }
    }

    // MARK: - Input

    private var inputArea: some View {
        VStack(spacing: 0) {
            if let error = agent.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(themeManager.error)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(themeManager.error)
                        .lineLimit(2)
                    Spacer()
                    Button(action: { agent.errorMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(themeManager.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            if !agent.selectedTextSnippets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("已选中文本")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(themeManager.textSecondary)
                        Spacer()
                        Button("清空") {
                            agent.clearSelectedTextSnippets()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.borderless)
                        .foregroundColor(themeManager.textMuted)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(agent.selectedTextSnippets) { snippet in
                                SelectedTextChip(
                                    snippet: snippet,
                                    agent: agent,
                                    themeManager: themeManager
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $inputText)
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 44, maxHeight: 140)
                        .padding(8)
                        .background(themeManager.backgroundTertiary)
                        .cornerRadius(10)

                    if inputText.isEmpty {
                        Text("输入问题…（⌘ + Enter 发送）")
                            .font(.system(size: 13))
                            .foregroundColor(themeManager.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

                VStack(spacing: 8) {
                    Button(action: { showingFilePicker = true }) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 14))
                            .foregroundColor(themeManager.textSecondary)
                    }
                    .help("添加本地文件引用")

                    if agent.isProcessing {
                        Button(action: { agent.cancelRun() }) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(themeManager.error)
                        }
                        .help("停止生成")
                    } else {
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                 ? themeManager.textMuted
                                                 : themeManager.accent)
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("发送（⌘ + Enter）")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .padding(.top, 8)
        }
        .background(themeManager.backgroundSecondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(themeManager.border),
            alignment: .top
        )
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.plainText, .markdown, .latex, .html, .pdf, .sourceCode, .data],
            allowsMultipleSelection: true
        ) { result in
            handleFileSelection(result)
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        agent.sendMessage(text, documentText: documentText)
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                for url in urls {
                    await agent.addReferencedFile(path: url.path)
                }
            }
        case .failure(let error):
            agent.errorMessage = "选择文件失败: \(error.localizedDescription)"
        }
    }

    private func exportConversation() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        var lines: [String] = []
        lines.append("# TechMarkdown AI 对话记录")
        lines.append("导出时间：\(formatter.string(from: Date()))")
        lines.append("")

        for message in agent.messages.filter({ $0.role != .tool }) {
            let role = message.isUser ? "用户" : "AI"
            lines.append("## \(role) · \(formatter.string(from: message.timestamp))")
            if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                lines.append("> 思考过程：\(reasoning)")
                lines.append("")
            }
            lines.append(message.content.isEmpty ? "（无内容）" : message.content)
            lines.append("")
        }

        let markdown = lines.joined(separator: "\n")

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AI对话记录_\(fileFormatter.string(from: Date())).md"
        panel.allowedContentTypes = [.plainText]
        panel.title = "导出对话记录"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                agent.errorMessage = "导出失败: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Header Button

struct HeaderButton: View {
    let icon: String
    let help: String
    @Environment(ThemeManager.self) var themeManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(themeManager.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(themeManager.backgroundTertiary.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Referenced File Chip

struct ReferencedFileChip: View {
    let file: ReferencedFile
    @Bindable var agent: AIAgent
    @Bindable var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.isIncluded ? "doc.text.fill" : "doc.text")
                .font(.system(size: 11))
                .foregroundColor(file.isIncluded ? themeManager.accent : themeManager.textMuted)

            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundColor(file.isIncluded ? themeManager.textPrimary : themeManager.textMuted)

            Button(action: { agent.removeReferencedFile(id: file.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(file.isIncluded ? themeManager.accent.opacity(0.12) : themeManager.backgroundTertiary)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(file.isIncluded ? themeManager.accent.opacity(0.25) : themeManager.border, lineWidth: 1)
        )
        .onTapGesture {
            agent.toggleReferencedFile(id: file.id)
        }
    }
}

// MARK: - Selected Text Chip

struct SelectedTextChip: View {
    let snippet: SelectedTextSnippet
    @Bindable var agent: AIAgent
    @Bindable var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.cursor")
                .font(.system(size: 11))
                .foregroundColor(themeManager.accent)

            Text(snippet.preview)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundColor(themeManager.textPrimary)

            Button(action: { agent.removeSelectedTextSnippet(id: snippet.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(themeManager.accent.opacity(0.12))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(themeManager.accent.opacity(0.25), lineWidth: 1)
        )
        .help(snippet.content)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    @Bindable var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: 0) {
            if message.isUser { Spacer(minLength: 40) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                    ReasoningView(reasoning: reasoning, themeManager: themeManager)
                }

                if message.isUser {
                    let displayContent = message.content.isEmpty ? "（无内容）" : message.content
                    Text(displayContent)
                        .font(.system(size: 13))
                        .padding(10)
                        .background(themeManager.accent.opacity(0.15))
                        .foregroundColor(themeManager.accent)
                        .cornerRadius(12)

                    if !message.referencedFiles.isEmpty {
                        MessageAttachmentSummary(
                            files: message.referencedFiles,
                            themeManager: themeManager
                        )
                    }
                } else {
                    MarkdownMessageView(
                        content: message.content.isEmpty ? "（无内容）" : message.content,
                        themeManager: themeManager
                    )
                        .padding(12)
                        .background(themeManager.backgroundTertiary)
                        .cornerRadius(12)
                }

                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    ToolCallsDisclosureView(
                        toolCalls: toolCalls,
                        themeManager: themeManager
                    )
                }

                HStack(spacing: 6) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(themeManager.textMuted)

                    if !message.isUser, !message.content.isEmpty {
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundColor(themeManager.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("复制")
                    }
                }
                .padding(.horizontal, 4)
            }

            if !message.isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Streaming Message Bubble

struct StreamingMessageBubble: View {
    let content: String
    let reasoning: String
    let toolCallName: String?
    @Bindable var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 6) {
                if !reasoning.isEmpty {
                    ReasoningView(reasoning: reasoning, themeManager: themeManager)
                }

                MarkdownMessageView(
                    content: content.isEmpty ? "（生成中…）" : content,
                    themeManager: themeManager
                )
                    .padding(12)
                    .background(themeManager.backgroundTertiary)
                    .cornerRadius(12)

                if let toolCallName = toolCallName {
                    HStack(spacing: 4) {
                        Image(systemName: "hammer.fill")
                            .font(.caption2)
                            .foregroundColor(themeManager.warning)
                        Text("调用: \(toolCallName)")
                            .font(.caption2)
                            .foregroundColor(themeManager.textMuted)
                    }
                    .padding(.horizontal, 4)
                }

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("生成中…")
                        .font(.caption2)
                        .foregroundColor(themeManager.textMuted)
                }
                .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MessageAttachmentSummary: View {
    let files: [ReferencedFile]
    @Bindable var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("本轮已发送")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(themeManager.textMuted)

            ForEach(files) { file in
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.fill")
                    Text((file.path as NSString).lastPathComponent)
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(themeManager.accentSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(themeManager.accentSecondary.opacity(0.12))
                )
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Diff Summary

struct DiffSummaryView: View {
    let originalText: String
    let suggestedText: String
    @Bindable var themeManager: ThemeManager

    var body: some View {
        let diff = computeLineDiff(oldText: originalText, newText: suggestedText)
        let added = diff.filter { $0.type == .added }.count
        let removed = diff.filter { $0.type == .removed }.count

        HStack(spacing: 16) {
            Label("+\(added)", systemImage: "plus.circle")
                .foregroundColor(themeManager.success)
            Label("-\(removed)", systemImage: "minus.circle")
                .foregroundColor(themeManager.error)
            Label("\(suggestedText.count) 字符", systemImage: "textformat")
                .foregroundColor(themeManager.textMuted)
            Spacer()
        }
        .font(.caption)
    }
}

// MARK: - Skill Picker

struct SkillPickerView: View {
    @Bindable var agent: AIAgent
    let documentText: String
    @Binding var isPresented: Bool
    @Bindable var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("选择 Skill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(themeManager.textPrimary)
                Spacer()
                Button("完成") { isPresented = false }
            }
            .padding()

            Divider()
                .background(themeManager.border)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(BuiltInSkill.all) { skill in
                        Button(action: {
                            isPresented = false
                            agent.runSkill(skill, documentText: documentText)
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: skill.icon)
                                    .frame(width: 24)
                                    .foregroundColor(themeManager.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(themeManager.textPrimary)
                                    Text(skill.description)
                                        .font(.caption)
                                        .foregroundColor(themeManager.textMuted)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(themeManager.backgroundPrimary)
                        Divider()
                            .background(themeManager.border)
                    }
                }
            }
        }
        .frame(width: 280, height: 360)
        .background(themeManager.backgroundSecondary)
    }
}

// MARK: - Reasoning View

struct ReasoningView: View {
    let reasoning: String
    @Bindable var themeManager: ThemeManager
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                Text(reasoning)
                    .font(.system(size: 12))
                    .italic()
                    .foregroundColor(themeManager.textSecondary)
                    .padding(8)
                    .background(themeManager.backgroundCode)
                    .cornerRadius(8)
            },
            label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.caption2)
                        .foregroundColor(themeManager.accentSecondary)
                    Text("过程摘要")
                        .font(.caption2)
                        .foregroundColor(themeManager.accentSecondary)
                }
            }
        )
        .padding(.horizontal, 4)
    }
}

private struct ToolCallsDisclosureView: View {
    let toolCalls: [ToolCall]
    @Bindable var themeManager: ThemeManager
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(toolCalls) { call in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.caption2)
                            .foregroundStyle(themeManager.success)
                        Text(call.function.name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(themeManager.textSecondary)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.leading, 4)
        } label: {
            Label(
                "\(toolCalls.count) 次工具调用",
                systemImage: "hammer"
            )
            .font(.caption2)
            .foregroundStyle(themeManager.textMuted)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Conversation History

struct ConversationHistoryView: View {
    @Bindable var agent: AIAgent
    @Bindable var themeManager: ThemeManager
    let currentDocumentText: String
    @Environment(\.dismiss) var dismiss
    @State private var conversations: [Conversation] = []
    @State private var scope: ConversationHistoryScope = .currentFile

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("对话历史")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(themeManager.textPrimary)
                Spacer()
                Button {
                    agent.startNewConversation(documentText: currentDocumentText)
                    dismiss()
                } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .tint(themeManager.accent)

                Button("关闭") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(themeManager.backgroundSecondary)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(themeManager.border),
                alignment: .bottom
            )

            Picker("范围", selection: $scope) {
                ForEach(ConversationHistoryScope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            if conversations.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundColor(themeManager.textMuted.opacity(0.5))
                    Text("暂无历史对话")
                        .foregroundColor(themeManager.textMuted)
                }
                Spacer()
            } else {
                List {
                    ForEach(conversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            agent: agent,
                            themeManager: themeManager,
                            currentDocumentText: currentDocumentText,
                            onContinue: { dismiss() },
                            onDelete: { refresh() }
                        )
                    }
                }
                .scrollContentBackground(.hidden)
                .background(themeManager.backgroundPrimary)
            }
        }
        .background(themeManager.backgroundPrimary)
        .onAppear {
            if agent.currentFilePath == nil {
                scope = .all
            }
            refresh()
        }
        .onChange(of: scope) { _, _ in
            refresh()
        }
    }

    private func refresh() {
        conversations = scope == .currentFile
            ? agent.conversationsForCurrentFile()
            : agent.allConversations()
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    @Bindable var agent: AIAgent
    @Bindable var themeManager: ThemeManager
    let currentDocumentText: String
    let onContinue: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title)
                    .font(.system(size: 13))
                    .foregroundColor(themeManager.textPrimary)
                    .lineLimit(1)
                Text("\(conversation.messages.count) 条消息 · \(conversation.updatedAt, style: .date) \(conversation.updatedAt, style: .time)")
                    .font(.caption2)
                    .foregroundColor(themeManager.textMuted)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("继续") {
                    agent.loadConversation(
                        conversation,
                        currentDocumentText: currentDocumentText
                    )
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: {
                    deleteConversation(conversation)
                    onDelete()
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(themeManager.error)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(themeManager.backgroundSecondary)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(themeManager.border, lineWidth: 1)
        )
    }

    private func deleteConversation(_ conversation: Conversation) {
        agent.deleteConversation(conversation)
    }
}

private enum ConversationHistoryScope: String, CaseIterable, Identifiable {
    case currentFile
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentFile: return "当前文件"
        case .all: return "全部对话"
        }
    }
}

// MARK: - AG-UI Event Log

struct AGUIEventLogView: View {
    let events: [AGUIEvent]
    @Bindable var themeManager: ThemeManager
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AG-UI 事件流")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(themeManager.textSecondary)
                Spacer()
                Text("\(events.count) 个事件")
                    .font(.caption2)
                    .foregroundColor(themeManager.textMuted)
                if let onClose = onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(themeManager.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()
                .background(themeManager.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(events) { event in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(event.type.color)
                                    .frame(width: 6, height: 6)
                                Text(event.type.rawValue)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(event.type.color)
                                Text(event.payload.summary)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundColor(themeManager.textPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .id(event.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: events.count) { _, _ in
                    if let last = events.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(themeManager.backgroundSecondary)
    }
}

extension AGUIEventType {
    var color: Color {
        switch self {
        case .runStarted, .runFinished: return .blue
        case .runError: return .red
        case .textMessageStart, .textMessageContent, .textMessageEnd, .textMessageChunk: return .green
        case .toolCallStart, .toolCallArgs, .toolCallEnd, .toolCallResult, .toolCallChunk: return .orange
        case .stateSnapshot, .stateDelta, .messagesSnapshot: return .purple
        case .reasoningStart, .reasoningMessageStart, .reasoningMessageContent, .reasoningMessageEnd, .reasoningEnd: return .teal
        case .activitySnapshot, .activityDelta, .stepStarted, .stepFinished: return .indigo
        case .raw, .custom: return .gray
        }
    }
}

struct AnnotationRow: View {
    let annotation: Annotation
    let path: String
    let documentText: String
    let onChange: () -> Void
    @Bindable var themeManager: ThemeManager

    @State private var isEditing = false
    @State private var editDraft = ""
    @State private var showDeleteConfirmation = false
    @FocusState private var isFocused: Bool

    private var anchorMatch: AnnotationMatch? {
        AnnotationLocator.locate(annotation, in: documentText)
    }

    private var hasValidAnchor: Bool {
        annotation.pdfAnchor != nil || anchorMatch != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Text(statusTitle)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(statusColor)

                Text(annotation.updatedAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(themeManager.textMuted)

                Spacer()

                Menu {
                    Button {
                        startEdit()
                    } label: {
                        Label("编辑批注", systemImage: "pencil")
                    }

                    Button {
                        toggleResolved()
                    } label: {
                        Label(
                            annotation.resolved ? "重新打开" : "标记为已解决",
                            systemImage: annotation.resolved ? "arrow.uturn.backward.circle" : "checkmark.circle"
                        )
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("删除批注", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(themeManager.textMuted)
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .tint(themeManager.textSecondary)
                .fixedSize()
            }

            if !annotation.selectedText.isEmpty {
                Button {
                    jumpToSource()
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: hasValidAnchor ? "quote.opening" : "link.badge.plus")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(hasValidAnchor ? themeManager.annotationHighlight : themeManager.warning)
                            .padding(.top, 2)

                        Text(annotation.selectedText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(annotation.resolved ? themeManager.textMuted : themeManager.textSecondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                (hasValidAnchor ? themeManager.annotationHighlight : themeManager.warning)
                                    .opacity(0.08)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasValidAnchor)
                .help(hasValidAnchor ? "跳转到原文" : "原文已变化，无法自动定位")
            }

            if isEditing {
                VStack(alignment: .trailing, spacing: 7) {
                    TextEditor(text: $editDraft)
                        .font(.system(size: 12))
                        .foregroundStyle(themeManager.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 62, maxHeight: 120)
                        .padding(7)
                        .background(themeManager.backgroundPrimary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(themeManager.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .focused($isFocused)

                    HStack(spacing: 12) {
                        Button("取消", action: cancelEdit)
                            .foregroundStyle(themeManager.textMuted)
                        Button("保存", action: saveEdit)
                            .foregroundStyle(themeManager.accent)
                            .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                }
            } else {
                Text(annotation.text)
                    .font(.system(size: 12))
                    .foregroundStyle(annotation.resolved ? themeManager.textMuted : themeManager.textPrimary)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }

            if !annotation.context.isEmpty, annotation.selectedText.isEmpty {
                Text("全文意见")
                    .font(.system(size: 9))
                    .foregroundStyle(themeManager.textMuted)
            }
        }
        .padding(11)
        .background(themeManager.backgroundSecondary.opacity(annotation.resolved ? 0.48 : 0.86))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(statusColor)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(themeManager.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .confirmationDialog(
            "删除这条批注？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive, action: delete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不会修改文档正文。")
        }
    }

    private var statusTitle: String {
        if annotation.resolved { return "已解决" }
        if let anchor = annotation.pdfAnchor { return "PDF 第 \(anchor.pageIndex + 1) 页" }
        if annotation.selectedText.isEmpty { return "全文意见" }
        guard let anchorMatch else { return "原文已变化" }
        return anchorMatch.quality == .exact ? "已定位" : "已重定位"
    }

    private var statusColor: Color {
        if annotation.resolved { return themeManager.success }
        if !annotation.selectedText.isEmpty, !hasValidAnchor { return themeManager.warning }
        return themeManager.annotationHighlight
    }

    private func jumpToSource() {
        if let anchor = annotation.pdfAnchor {
            NotificationCenter.default.post(name: .navigatePDFPage, object: anchor.pageIndex)
            return
        }
        NotificationCenter.default.post(name: .scrollEditorToAnnotation, object: annotation)
        NotificationCenter.default.post(name: .scrollPreviewToAnnotation, object: annotation)
    }

    private func startEdit() {
        editDraft = annotation.text
        isEditing = true
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func cancelEdit() {
        isEditing = false
        editDraft = ""
    }

    private func saveEdit() {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AnnotationService.shared.updateAnnotationText(id: annotation.id, newText: trimmed, for: path)
        isEditing = false
        editDraft = ""
        onChange()
    }

    private func toggleResolved() {
        AnnotationService.shared.toggleResolved(id: annotation.id, for: path)
        onChange()
    }

    private func delete() {
        AnnotationService.shared.deleteAnnotation(id: annotation.id, for: path)
        onChange()
    }
}

struct HunkRow: View {
    let hunk: EditHunk
    let isSelected: Bool
    @Bindable var themeManager: ThemeManager
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(get: { isSelected }, set: { onToggle($0) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                if hunk.isInsertion {
                    ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { _, line in
                        HunkLine(text: line, color: themeManager.success, prefix: "+")
                    }
                } else if hunk.isDeletion {
                    ForEach(Array(hunk.oldLines.enumerated()), id: \.offset) { _, line in
                        HunkLine(text: line, color: themeManager.error, prefix: "-")
                    }
                } else {
                    ForEach(Array(hunk.oldLines.enumerated()), id: \.offset) { _, line in
                        HunkLine(text: line, color: themeManager.error, prefix: "-")
                    }
                    ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { _, line in
                        HunkLine(text: line, color: themeManager.success, prefix: "+")
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .padding(6)
        .background(themeManager.backgroundTertiary.opacity(0.5))
        .cornerRadius(6)
    }
}

struct HunkLine: View {
    let text: String
    let color: Color
    let prefix: String

    var body: some View {
        HStack(spacing: 4) {
            Text(prefix)
                .foregroundColor(color)
                .frame(width: 14, alignment: .leading)
            Text(text.isEmpty ? " " : text)
                .foregroundColor(color)
            Spacer()
        }
    }
}

extension Notification.Name {
    static let showPendingEditDiff = Notification.Name("showPendingEditDiff")
    static let annotationListChanged = Notification.Name("annotationListChanged")
    static let requestAnnotationComposer = Notification.Name("requestAnnotationComposer")
    static let focusAnnotation = Notification.Name("focusAnnotation")
    static let scrollEditorToAnnotation = Notification.Name("scrollEditorToAnnotation")
    static let scrollPreviewToAnnotation = Notification.Name("scrollPreviewToAnnotation")
    static let navigatePDFPage = Notification.Name("navigatePDFPage")
}
