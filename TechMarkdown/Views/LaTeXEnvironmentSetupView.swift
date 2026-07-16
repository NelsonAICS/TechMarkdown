import SwiftUI

/// LaTeX 编译环境管理面板。
///
/// 允许用户一键下载/安装 Tectonic，或查看当前是否已存在系统 LaTeX 工具。
struct LaTeXEnvironmentSetupView: View {
    @Environment(\.dismiss) var dismiss
    @State private var statusText = "检测中…"
    @State private var isInstalled = false
    @State private var isInstalling = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            header
            statusIcon
            statusDescription
            progressSection
            errorSection
            actionButtons
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 320)
        .onAppear(perform: refreshStatus)
    }

    private var header: some View {
        Text("LaTeX 编译环境")
            .font(.title2)
            .fontWeight(.bold)
    }

    private var statusIcon: some View {
        Image(systemName: isInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 56))
            .foregroundColor(isInstalled ? .green : .orange)
    }

    private var statusDescription: some View {
        Text(statusText)
            .font(.system(size: 13))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var progressSection: some View {
        if isInstalling {
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 280)
                Text("正在下载 Tectonic… \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = errorMessage {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])

            if !isInstalled {
                Button("一键安装 Tectonic") {
                    installTectonic()
                }
                .disabled(isInstalling)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func refreshStatus() {
        if TectonicManager.shared.isInstalled {
            isInstalled = true
            statusText = "Tectonic 已安装，可以直接编译 LaTeX 文档。"
        } else if LaTeXCompilerService.shared.canCompile {
            isInstalled = true
            statusText = "检测到系统已安装 LaTeX 工具（xelatex/pdflatex），可直接编译。"
        } else {
            isInstalled = false
            statusText = "未检测到 LaTeX 编译环境。点击「一键安装 Tectonic」下载内置引擎（约 20–30 MB），或手动安装 MacTeX/TinyTeX。"
        }
    }

    private func installTectonic() {
        isInstalling = true
        progress = 0
        errorMessage = nil

        Task {
            do {
                try await TectonicManager.shared.install { p in
                    Task { @MainActor in
                        progress = p
                    }
                }
                await MainActor.run {
                    isInstalling = false
                    refreshStatus()
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
