import Foundation

/// 本地 API Key 存储
///
/// 原实现使用 Keychain，但在开发阶段每次重新 Build 后签名/Bundle ID 可能变化，
/// 导致系统反复弹出“访问机密信息”的授权对话框。改为使用 UserDefaults + 简单混淆后，
/// 既能避免授权弹窗，又能满足本地沙盒应用的基本安全需求。
/// 发布到 App Store / 分发版本时可考虑重新切回 Keychain 并配置 Keychain Access Group。
final class KeychainService {
    static let shared = KeychainService()
    private let defaults = UserDefaults.standard
    private let prefix = "techmarkdown.apiKey."

    private init() {}

    func save(apiKey: String, account: String) -> Bool {
        let key = prefixKey(account)
        let encoded = apiKey.data(using: .utf8)?.base64EncodedString() ?? apiKey
        defaults.set(encoded, forKey: key)
        return true
    }

    func load(account: String) -> String? {
        let key = prefixKey(account)
        guard let encoded = defaults.string(forKey: key) else { return nil }
        if let data = Data(base64Encoded: encoded),
           let apiKey = String(data: data, encoding: .utf8) {
            return apiKey
        }
        // 兼容未编码的旧数据
        return encoded
    }

    func delete(account: String) {
        let key = prefixKey(account)
        defaults.removeObject(forKey: key)
    }

    private func prefixKey(_ account: String) -> String {
        return prefix + account
    }
}
