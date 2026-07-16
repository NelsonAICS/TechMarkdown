import Foundation
import AppKit

enum LaTeXCompilerError: Error, LocalizedError {
    case noCompilerFound
    case compilationFailed(String)
    case invalidSource
    case saveCancelled

    var errorDescription: String? {
        switch self {
        case .noCompilerFound:
            return "未找到 LaTeX 编译环境。请在「设置 → LaTeX 环境」中一键安装 Tectonic，或手动安装 MacTeX/TinyTeX。"
        case .compilationFailed(let msg):
            return "编译失败: \(msg)"
        case .invalidSource:
            return "LaTeX 源码为空或无效"
        case .saveCancelled:
            return "用户取消保存"
        }
    }
}

/// 调用本地 LaTeX 工具链将 .tex 源码编译为 PDF。
///
/// 优先使用 App 内置/自动安装的 Tectonic；若用户系统已安装 xelatex/pdflatex，也可作为后备。
final class LaTeXCompilerService {
    static let shared = LaTeXCompilerService()

    private init() {}

    // MARK: - Compiler discovery

    /// 返回可用的编译器完整路径。
    /// 优先级：已安装的 Tectonic > 系统 xelatex > 系统 pdflatex。
    func availableCompiler() -> String? {
        if let tectonic = TectonicManager.shared.executableURL() {
            return tectonic.path
        }
        for compiler in ["xelatex", "pdflatex"] {
            if let fullPath = path(for: compiler) {
                return fullPath
            }
        }
        return nil
    }

    /// 是否已准备好编译 LaTeX。
    var canCompile: Bool {
        availableCompiler() != nil
    }

    /// 检测指定命令是否在 PATH 中可用。
    private func path(for command: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [command]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return task.terminationStatus == 0 && !output.isEmpty ? output : nil
        } catch {
            return nil
        }
    }

    // MARK: - Compile

    /// 编译 LaTeX 源码，返回生成的 PDF 临时文件 URL。
    func compile(text: String, fileURL: URL? = nil) async throws -> URL {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LaTeXCompilerError.invalidSource
        }

        guard let compiler = availableCompiler() else {
            throw LaTeXCompilerError.noCompilerFound
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let sourceName = fileURL?.deletingPathExtension().lastPathComponent ?? "document"
        let sourceURL = workDir.appendingPathComponent("\(sourceName).tex")
        try text.write(to: sourceURL, atomically: true, encoding: .utf8)

        return try await compile(sourceURL: sourceURL, compiler: compiler)
    }

    /// 编译指定 .tex 文件，返回 PDF URL。
    func compile(sourceURL: URL) async throws -> URL {
        guard let compiler = availableCompiler() else {
            throw LaTeXCompilerError.noCompilerFound
        }
        return try await compile(sourceURL: sourceURL, compiler: compiler)
    }

    private func compile(sourceURL: URL, compiler: String) async throws -> URL {
        let workDir = sourceURL.deletingLastPathComponent()
        let pdfURL = workDir.appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + ".pdf")
        let isTectonic = compiler.lowercased().contains("tectonic")

        return try await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: compiler)

            if isTectonic {
                task.arguments = ["-X", "compile", sourceURL.lastPathComponent]
            } else {
                task.arguments = ["-interaction=nonstopmode", "-halt-on-error", sourceURL.lastPathComponent]
            }
            task.currentDirectoryURL = workDir

            // Tectonic 会把缓存放在 $HOME/.cache/Tectonic；在沙盒中重定向到 App Container。
            var env = ProcessInfo.processInfo.environment
            if isTectonic {
                env["HOME"] = TectonicManager.shared.appSupportDirectory.path
                env["TECTONIC_CACHE_DIR"] = TectonicManager.shared.cacheDirectory.path
            }
            task.environment = env

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe

            try task.run()
            task.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            guard task.terminationStatus == 0, FileManager.default.fileExists(atPath: pdfURL.path) else {
                let logs = (output + "\n" + errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = String(logs.suffix(2000))
                throw LaTeXCompilerError.compilationFailed(tail.isEmpty ? "未知错误" : tail)
            }

            return pdfURL
        }.value
    }

    // MARK: - Legacy direct-save flow (kept for callers that prefer it)

    /// 编译并弹出保存面板让用户下载 PDF。
    func compileAndSave(text: String, fileURL: URL?) {
        Task {
            do {
                let compiledPDF = try await compile(text: text, fileURL: fileURL)
                await MainActor.run {
                    showSavePanel(sourcePDF: compiledPDF, fileURL: fileURL)
                }
            } catch {
                await MainActor.run {
                    showError(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func showSavePanel(sourcePDF: URL, fileURL: URL?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let defaultName = (fileURL?.deletingPathExtension().lastPathComponent ?? "未命名") + ".pdf"
        panel.nameFieldStringValue = defaultName
        panel.title = "保存 PDF"
        panel.prompt = "下载"

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourcePDF, to: destination)

                let revealAlert = NSAlert()
                revealAlert.messageText = "PDF 下载成功"
                revealAlert.informativeText = "已保存到 \(destination.path)"
                revealAlert.alertStyle = .informational
                revealAlert.addButton(withTitle: "在 Finder 中显示")
                revealAlert.addButton(withTitle: "确定")
                if revealAlert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                self.showError("保存 PDF 失败: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "LaTeX 编译错误"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}
