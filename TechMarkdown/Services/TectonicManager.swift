import Foundation

enum TectonicError: Error, LocalizedError {
    case unsupportedArchitecture
    case downloadFailed(String)
    case installFailed(String)
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "不支持当前 Mac 架构，仅支持 Apple Silicon (arm64) 和 Intel (x86_64)。"
        case .downloadFailed(let msg):
            return "下载 Tectonic 失败: \(msg)"
        case .installFailed(let msg):
            return "安装 Tectonic 失败: \(msg)"
        case .notInstalled:
            return "Tectonic 未安装。"
        }
    }
}

/// 管理内置 Tectonic LaTeX 引擎的下载、安装与调用路径。
///
/// Tectonic 是独立的现代 LaTeX 引擎（基于 XeTeX），单个二进制、MIT 协议，
/// 适合随 App 分发或在首次使用时自动下载。
final class TectonicManager {
    static let shared = TectonicManager()

    private let version = "0.15.0"

    private init() {}

    // MARK: - Paths

    var appSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("TechMarkdown", isDirectory: true)
    }

    private var enginesDirectory: URL {
        appSupportDirectory.appendingPathComponent("engines", isDirectory: true)
    }

    var cacheDirectory: URL {
        appSupportDirectory.appendingPathComponent("cache/tectonic", isDirectory: true)
    }

    var installedURL: URL {
        enginesDirectory.appendingPathComponent("tectonic", isDirectory: false)
    }

    // MARK: - State

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path) &&
        FileManager.default.isExecutableFile(atPath: installedURL.path)
    }

    /// 返回可用的 tectonic 二进制路径；nil 表示未安装。
    func executableURL() -> URL? {
        isInstalled ? installedURL : nil
    }

    // MARK: - Install

    /// 从 GitHub Releases 下载并安装 Tectonic。
    /// - Parameter progress: 0.0 ~ 1.0 的下载进度回调。
    func install(progress: @escaping (Double) -> Void) async throws {
        let arch = currentArchitecture()
        let filename = "tectonic-\(version)-\(arch)-apple-darwin.tar.gz"
        let escapedVersion = version.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? version
        guard let downloadURL = URL(
            string: "https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%40\(escapedVersion)/\(filename)"
        ) else {
            throw TectonicError.downloadFailed("无效的下载地址")
        }

        try FileManager.default.createDirectory(at: enginesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent(filename)

        await MainActor.run { progress(0.1) }

        // 下载
        let (downloadedURL, response) = try await URLSession.shared.download(from: downloadURL)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TectonicError.downloadFailed("服务器返回 \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        await MainActor.run { progress(0.6) }

        // 移动到临时目录（download 返回的 URL 在临时目录，可能被清理）
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: archiveURL)

        await MainActor.run { progress(0.7) }

        // 解压
        try await extractTarGz(archiveURL: archiveURL, destination: tempDir)
        let extractedBinary = tempDir.appendingPathComponent("tectonic")
        guard FileManager.default.fileExists(atPath: extractedBinary.path) else {
            throw TectonicError.installFailed("解压后未找到 tectonic 二进制")
        }

        await MainActor.run { progress(0.9) }

        // 安装到 engines 目录
        if FileManager.default.fileExists(atPath: installedURL.path) {
            try FileManager.default.removeItem(at: installedURL)
        }
        try FileManager.default.copyItem(at: extractedBinary, to: installedURL)

        // 设置可执行权限并移除 Gatekeeper 隔离属性（否则沙盒内可能无法执行下载的二进制）
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installedURL.path
        )
        removeQuarantineAttribute(at: installedURL)

        await MainActor.run { progress(1.0) }
    }

    private func extractTarGz(archiveURL: URL, destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            task.arguments = ["-xzf", archiveURL.path, "-C", destination.path]

            let pipe = Pipe()
            task.standardError = pipe

            try task.run()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw TectonicError.installFailed(msg ?? "tar 解压失败")
            }
        }.value
    }

    private func currentArchitecture() -> String {
        #if arch(arm64)
        return "aarch64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// 移除下载文件可能附带的 Gatekeeper 隔离属性。
    private func removeQuarantineAttribute(at url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-d", "com.apple.quarantine", url.path]
        // 该属性可能不存在，忽略错误
        try? task.run()
        task.waitUntilExit()
    }
}
