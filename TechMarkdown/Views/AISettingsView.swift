import SwiftUI

struct AISettingsView: View {
    @Bindable var agent: AIAgent
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) var dismiss

    @State private var config: AIProviderConfiguration
    @State private var apiKey: String
    @State private var isTesting = false
    @State private var showingKey = false
    @State private var showMemoryEditor = false
    @State private var showMCPSettings = false
    @State private var showMCPHelp = false
    @State private var selectedPresetModel: String

    private let customModelToken = "__custom__"

    init(agent: AIAgent) {
        self.agent = agent
        let initialConfig = agent.configuration
        _config = State(initialValue: initialConfig)
        _apiKey = State(initialValue: "")
        _selectedPresetModel = State(initialValue: {
            let models = initialConfig.providerID.preset.models
            return models.contains(initialConfig.model) ? initialConfig.model : "__custom__"
        }())
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                providerSection
                modelSection
                apiKeySection
                actionSection
                memorySection
                advancedSection
                mcpSection
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(minWidth: 640, minHeight: 620)
        .background(themeManager.backgroundPrimary)
        .sheet(isPresented: $showMemoryEditor) {
            MemoryEditorView()
                .frame(minWidth: 620, minHeight: 520)
        }
        .sheet(isPresented: $showMCPSettings) {
            MCPSettingsView()
                .frame(minWidth: 640, minHeight: 560)
        }
        .sheet(isPresented: $showMCPHelp) {
            MCPHelpView()
                .frame(minWidth: 560, minHeight: 460)
        }
        .onAppear {
            apiKey = KeychainService.shared.load(account: config.apiKeyAccount) ?? ""
            agent.updateConfiguration(config, apiKey: apiKey)
            agent.checkConnection()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("AI 设置")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(themeManager.textPrimary)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(themeManager.textMuted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("关闭")
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
    }

    // MARK: - Provider

    private var providerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择 AI 服务商")
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.textMuted)

                Picker("服务商", selection: $config.providerID) {
                    ForEach(AIProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: config.providerID) { _, newValue in
                    let preset = newValue.preset
                    config.baseURL = preset.chatCompletionsURL
                    config.apiKeyAccount = preset.apiKeyName
                    if !preset.models.isEmpty {
                        config.model = preset.defaultModel
                        selectedPresetModel = preset.defaultModel
                    } else {
                        config.model = ""
                        selectedPresetModel = customModelToken
                    }
                    apiKey = KeychainService.shared.load(account: config.apiKeyAccount) ?? ""
                }

                if config.providerID == .tokenAPIGate {
                    Text("通过本地 TokenAPIGate 网关统一调用模型。请在下方「模型名称」中填写网关内的 providerId/modelId，例如 deepseek/deepseek-v4-pro。")
                        .font(.caption)
                        .foregroundColor(themeManager.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("AI 服务商")
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                let presets = config.providerID.preset.models

                if !presets.isEmpty {
                    Picker("模型", selection: $selectedPresetModel) {
                        ForEach(presets, id: \.self) { model in
                            Text(model).tag(model)
                        }
                        Text("自定义").tag(customModelToken)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: selectedPresetModel) { _, newValue in
                        if newValue != customModelToken {
                            config.model = newValue
                        }
                    }
                }

                let modelPrompt = config.providerID == .tokenAPIGate
                    ? "providerId/modelId，例如 deepseek/deepseek-v4-pro"
                    : "模型名称"
                TextField("", text: $config.model, prompt: Text(modelPrompt))
                    .disabled(!presets.isEmpty && selectedPresetModel != customModelToken)
                    .opacity(!presets.isEmpty && selectedPresetModel != customModelToken ? 0.5 : 1)

                TextField("", text: $config.baseURL, prompt: Text("API Base URL"))
            }
        } header: {
            Text("模型与接口")
        }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if showingKey {
                        TextField("", text: $apiKey, prompt: Text("粘贴或输入 API Key"))
                            .labelsHidden()
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .labelsHidden()
                    }

                    Button(action: { showingKey.toggle() }) {
                        Image(systemName: showingKey ? "eye.slash" : "eye")
                            .foregroundColor(themeManager.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help(showingKey ? "隐藏" : "显示")
                }

                Text("当前环境变量名：\(config.apiKeyAccount)")
                    .font(.caption)
                    .foregroundColor(themeManager.textMuted)

                if config.providerID == .tokenAPIGate {
                    Text("TokenAPIGate 网关已集中管理各厂商 API Key，此处可留空；如需网关本地鉴权再填写。")
                        .font(.caption)
                        .foregroundColor(themeManager.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("API Key")
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button("保存配置") {
                        saveConfiguration()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("测试连接") {
                        testConnection()
                    }
                    .disabled(isTesting || (apiKey.isEmpty && config.providerID != .tokenAPIGate))

                    Spacer()

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 8, height: 8)
                    Text(agent.connectionStatus)
                        .font(.caption)
                        .foregroundColor(connectionStatusColor)
                    Spacer()
                }
            }
        } header: {
            Text("连接")
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("用 Markdown 文件保存编辑偏好与风格，每次对话自动注入上下文。")
                    .font(.caption)
                    .foregroundColor(themeManager.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Button("编辑 AI 记忆") {
                    showMemoryEditor = true
                }
            }
        } header: {
            Text("核心记忆")
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Temperature")
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.textPrimary)
                    Spacer()
                    Text("\(String(format: "%.1f", config.temperature))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(themeManager.accent)
                        .monospacedDigit()
                }
                Slider(value: $config.temperature, in: 0...1, step: 0.1)

                Text("Temperature 控制模型输出的随机程度。数值越低，回答越稳定、可预测；数值越高，回答越有创意、多变。建议常规任务用 0.3-0.7，创意任务可适当提高。")
                    .font(.caption)
                    .foregroundColor(themeManager.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text("低")
                        .font(.caption2)
                        .foregroundColor(themeManager.textMuted)
                    Text("·")
                        .font(.caption2)
                        .foregroundColor(themeManager.textMuted)
                    Text("回答更稳定、可预测")
                        .font(.caption2)
                        .foregroundColor(themeManager.textSecondary)
                    Spacer()
                    Text("高")
                        .font(.caption2)
                        .foregroundColor(themeManager.textMuted)
                    Text("·")
                        .font(.caption2)
                        .foregroundColor(themeManager.textMuted)
                    Text("更有创意、多变")
                        .font(.caption2)
                        .foregroundColor(themeManager.textSecondary)
                }

                Stepper("历史轮数：\(config.maxHistoryTurns)", value: $config.maxHistoryTurns, in: 2...30)
                    .font(.system(size: 13))
            }
        } header: {
            Text("高级参数")
        }
    }

    // MARK: - MCP

    private var mcpSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("MCP（Model Context Protocol）让 AI 能够调用外部工具，例如文件系统、搜索引擎、数据库等。")
                    .font(.caption)
                    .foregroundColor(themeManager.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("管理 MCP 扩展") {
                        showMCPSettings = true
                    }

                    Button("查看入门指南") {
                        showMCPHelp = true
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("MCP Server")
        }
    }

    // MARK: - Helpers

    private var connectionStatusColor: Color {
        let status = agent.connectionStatus
        if status.contains("成功") {
            return themeManager.success
        } else if status.contains("失败") || status.contains("未配置") {
            return themeManager.error
        } else if status.contains("检测中") {
            return themeManager.warning
        }
        return themeManager.textMuted
    }

    private func saveConfiguration() {
        agent.updateConfiguration(config, apiKey: apiKey)
        _ = KeychainService.shared.save(apiKey: apiKey, account: config.apiKeyAccount)
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "techmarkdown.aiConfig")
        }
        agent.connectionStatus = "配置已保存"
    }

    private func testConnection() {
        isTesting = true
        agent.updateConfiguration(config, apiKey: apiKey)
        Task {
            do {
                let response = try await AIService.shared.chat(
                    messages: [ChatMessage(role: .user, content: "请只回复 OK，测试连接。")],
                    documentText: "",
                    referencedFiles: [],
                    selectedTextSnippets: [],
                    tools: [],
                    configuration: config,
                    apiKey: apiKey
                )
                await MainActor.run {
                    isTesting = false
                    let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    agent.connectionStatus = trimmed.isEmpty
                        ? "连接成功，但模型返回为空"
                        : "连接成功: \(trimmed.prefix(30))"
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    agent.connectionStatus = "连接失败: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - MCP 入门指南

struct MCPHelpView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MCP 入门指南")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(themeManager.textPrimary)
                Spacer()
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

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("MCP（Model Context Protocol）是一种让 AI 调用外部工具的标准协议。配置后，AI 就能使用文件系统、搜索引擎、数据库等能力来回答你的问题。")
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    tutorialStep(number: 1, title: "启动 MCP Server", content: "搭建或启动一个兼容 MCP 的服务端，并确保它以 HTTP/SSE 模式运行。常见实现有 Python、Node.js 或 Go 的官方示例。")

                    tutorialStep(number: 2, title: "确认接口地址", content: "服务端通常暴露如下端点：/initialize、/notifications/initialized、/tools/list、/tools/call。在下方填写完整 URL，例如 http://localhost:3000/sse 或 http://localhost:3000/mcp。")

                    tutorialStep(number: 3, title: "添加并连接", content: "在 AI 设置页的“MCP Server”中输入名称与端点 URL，按需填写认证 Token，点击“添加”，再点击“连接全部”。")

                    tutorialStep(number: 4, title: "验证工具发现", content: "连接成功后，已注册的 Server 下方会显示“已发现 N 个工具”。此时回到对话，AI 会自动判断是否需要调用这些工具。")

                    HStack(spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(themeManager.warning)
                        Text("提示：如果暂时没有 MCP Server，可以先使用内置工具（搜索当前文档、读取本地文件、应用 Markdown 修改）测试 AI 的多步执行能力。")
                            .font(.caption)
                            .foregroundColor(themeManager.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(12)
                    .background(themeManager.backgroundSecondary)
                    .cornerRadius(8)
                }
                .padding(20)
            }
            .background(themeManager.backgroundPrimary)
        }
        .background(themeManager.backgroundPrimary)
    }

    private func tutorialStep(number: Int, title: String, content: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(themeManager.backgroundPrimary)
                .frame(width: 22, height: 22)
                .background(themeManager.accent)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(themeManager.textPrimary)
                Text(content)
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - AI 核心记忆编辑器

struct MemoryEditorView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) var dismiss
    @State private var memoryText = ""
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑 AI 核心记忆")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(themeManager.textPrimary)
                Spacer()
                if saved {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(themeManager.success)
                }
                Button("保存") {
                    MemoryService.shared.saveMemory(memoryText)
                    saved = true
                }
                .buttonStyle(.borderedProminent)
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

            TextEditor(text: $memoryText)
                .font(.system(size: 14))
                .foregroundColor(themeManager.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(themeManager.backgroundPrimary)
        }
        .background(themeManager.backgroundPrimary)
        .onAppear {
            memoryText = MemoryService.shared.loadMemory()
        }
        .onChange(of: memoryText) { _, _ in
            saved = false
        }
    }
}

// MARK: - MCP 设置

struct MCPSettingsView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) var dismiss
    @State private var mcpManager = MCPManager.shared
    @State private var newName = ""
    @State private var newEndpoint = ""
    @State private var newTransport: MCPConfiguration.MCPTransport = .http
    @State private var newAuthToken = ""
    @State private var newTimeout: Double = 30

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MCP 扩展管理")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(themeManager.textPrimary)
                Spacer()
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

            Form {
                registeredServersSection
                addServerSection
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(themeManager.backgroundPrimary)
        .onChange(of: mcpManager.configurations) { _, _ in
            mcpManager.saveConfigurations()
        }
        .onAppear {
            Task {
                await mcpManager.connectAll()
            }
        }
    }

    private var registeredServersSection: some View {
        Section {
            if mcpManager.configurations.isEmpty {
                Text("暂无已注册的 MCP Server")
                    .font(.caption)
                    .foregroundColor(themeManager.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(mcpManager.configurations) { config in
                    ServerConfigRow(
                        config: config,
                        mcpManager: mcpManager,
                        themeManager: themeManager
                    )
                    .padding(.vertical, 6)
                }

                if !mcpManager.discoveredTools.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(themeManager.success)
                            .font(.caption)
                        Text("已发现 \(mcpManager.discoveredTools.count) 个工具")
                            .font(.caption)
                            .foregroundColor(themeManager.success)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        } header: {
            Text("已注册的 MCP Server")
        }
    }

    private var addServerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("MCP Server 需要暴露 HTTP 接口：/initialize、/notifications/initialized、/tools、/call。认证 Token 为可选。")
                    .font(.caption)
                    .foregroundColor(themeManager.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("名称", text: $newName)
                TextField("端点 URL", text: $newEndpoint)

                Picker("传输协议", selection: $newTransport) {
                    ForEach(MCPConfiguration.MCPTransport.allCases, id: \.self) { t in
                        Text(t.rawValue.uppercased()).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("认证 Token")
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.textSecondary)
                    Spacer()
                    SecureField("可选", text: $newAuthToken)
                        .frame(maxWidth: 280)
                }

                HStack {
                    Text("超时（秒）")
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.textSecondary)
                    Spacer()
                    TextField("30", value: $newTimeout, format: .number)
                        .frame(width: 80)
                }

                HStack(spacing: 12) {
                    Button("添加") {
                        guard !newName.isEmpty, !newEndpoint.isEmpty else { return }
                        mcpManager.addConfiguration(MCPConfiguration(
                            id: UUID(),
                            name: newName,
                            transport: newTransport,
                            endpoint: newEndpoint,
                            isEnabled: true,
                            authToken: newAuthToken.isEmpty ? nil : newAuthToken,
                            timeout: newTimeout
                        ))
                        newName = ""
                        newEndpoint = ""
                        newAuthToken = ""
                        newTimeout = 30
                    }
                    .buttonStyle(.borderedProminent)

                    Button("连接全部") {
                        Task {
                            await mcpManager.connectAll()
                        }
                    }

                    Spacer()
                }
                .padding(.top, 4)
            }
        } header: {
            Text("添加 MCP Server")
        }
    }
}

// MARK: - MCP Server Row

struct ServerConfigRow: View {
    let config: MCPConfiguration
    @Bindable var mcpManager: MCPManager
    @Bindable var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(config.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(themeManager.textPrimary)
                    Text(config.endpoint)
                        .font(.caption)
                        .foregroundColor(themeManager.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("启用", isOn: Binding(
                    get: { config.isEnabled },
                    set: { newValue in
                        if let index = mcpManager.configurations.firstIndex(where: { $0.id == config.id }) {
                            mcpManager.configurations[index].isEnabled = newValue
                        }
                    }
                ))
                .toggleStyle(.switch)

                Button("重连") {
                    Task {
                        await mcpManager.reconnect(clientName: config.name)
                    }
                }
                .disabled(!config.isEnabled)

                Button(action: { mcpManager.removeConfiguration(id: config.id) }) {
                    Image(systemName: "trash")
                        .foregroundColor(themeManager.error)
                }
                .buttonStyle(.plain)
            }

            if let error = mcpManager.connectionErrors[config.name] {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(themeManager.error)
                        .font(.caption2)
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(themeManager.error)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(themeManager.backgroundSecondary)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(themeManager.border, lineWidth: 1)
        )
    }
}
