# 问题与解决方案

## 1. Xcode 不可用，如何验证编译？

### 问题

当前环境 `xcodebuild` 报错：

```
active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

无法使用 Xcode 编译 SwiftUI macOS 项目。

### 解决方案

- 项目改为 **Swift Package Manager** 结构。
- 使用 `swift build` 验证编译。
- 界面预览用 **SwiftUI Canvas** 在 Xcode 中打开，必要时单独用 `swiftc` 验证无 UI 的逻辑模块。

### 经验

SPM 是跨平台 Swift 项目的标准构建工具，适合 CLI 验证和 CI/CD。macOS App 仍可保留 `.xcodeproj`，但核心代码用 SPM 管理更灵活。

---

## 2. `AIAgent.configuration` 访问权限问题

### 问题

`AISettingsView` 需要读取和修改 `AIAgent` 的配置，但 `configuration` 属性声明为 `private`，导致编译错误：

```
'configuration' is inaccessible due to 'private' protection level
```

### 解决方案

将 `AIAgent.configuration` 从 `private(set)` 改为 `internal`：

```swift
final class AIAgent: ObservableObject {
    @Published var configuration: AIProviderConfiguration
    ...
}
```

同时提供 `saveConfiguration()` 方法，保存时同步写入 UserDefaults 和 Keychain。

### 经验

SwiftUI `@StateObject` 和 `@ObservedObject` 要求被观察的属性可访问，才能在 UI 中绑定。对于需要 UI 直接修改的模型属性，不能设为 private。

---

## 3. `applyPendingEdit` 参数类型不匹配

### 问题

`AISidebarView` 中调用：

```swift
agent.applyPendingEdit(to: &documentText)
```

但 `documentText` 是 `String`，而 `applyPendingEdit` 原签名期望 `MarkdownDocument`。

### 解决方案

将 `applyPendingEdit` 改为直接操作 `String`：

```swift
func applyPendingEdit(to documentText: inout String) -> Bool {
    guard let edit = pendingEdit else { return false }
    documentText = edit.proposedText
    pendingEdit = nil
    return true
}
```

并在 `ContentView` 中通过 `@State` 或 `@Binding` 同步文档文本。

### 经验

在 SwiftUI 中，文档状态通常以字符串形式存在于 View 层。AI 修改只需要替换字符串，不需要直接操作 `MarkdownDocument` 模型，这样职责更清晰。

---

## 4. 流式输出与 UI 刷新

### 问题

LLM 流式输出时，需要在每个 SSE chunk 到达后立即更新 UI，同时保持 SwiftUI 性能。

### 解决方案

- 使用 `@Published var streamingContent: String`。
- 在每个 chunk 到达时追加内容：

```swift
await MainActor.run {
    self.streamingContent += chunk
}
```

- 使用 `MainActor.run` 确保 UI 更新在主线程。
- 最终流结束后将完整内容加入 `messages`。

### 经验

流式更新要避免频繁触发 UI 重绘。当前每来一个 chunk 就更新一次，对于 Markdown 渲染来说可以接受；如果文本很长，可以考虑按 100ms 批量合并 chunk。

---

## 5. 工具调用结果跨组件传递

### 问题

`ToolRegistry` 是单例，不持有 `MarkdownDocument` 或 ViewModel，但需要访问当前文档内容（如 `search_in_document`）。

### 解决方案

使用 `UserDefaults` 作为轻量级跨组件状态中转：

```swift
UserDefaults.standard.set(documentText, forKey: "techmarkdown.currentDocumentText")
```

工具执行时读取该值。更优雅的未来方案是引入依赖注入容器（如 EnvironmentObject）传递当前文档上下文。

### 经验

简单场景下 `UserDefaults` 够用，但它是全局可变状态，不适合复杂应用。生产环境建议使用 `@Environment` 或专门的依赖注入框架。

---

## 6. API Key 安全存储

### 问题

API Key 不能明文存储在 UserDefaults 或 plist 中。

### 解决方案

- 使用 macOS Keychain 存储 API Key。
- `KeychainService` 封装了 `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`。
- 配置对象中只保存 account 标识，不保存 key 本身。

### 经验

Keychain 是 macOS/iOS 存储敏感数据的标准方式，支持访问控制和加密。SwiftUI 中常在保存时写入 Keychain，读取时从 Keychain 取出。

---

## 7. 多 Provider 兼容性

### 问题

OpenAI、Gemini、豆包、通义千问等 Provider 的 API 格式不同，如何统一？

### 解决方案

- 优先支持 **OpenAI 兼容格式**，这是事实标准。
- 豆包、通义千问都提供 OpenAI 兼容 endpoint。
- 对于 Gemini 原生 API，未来可在 `AIProviderPreset` 中标记 `format`，再单独适配。

### 经验

OpenAI 兼容接口大大降低了多 Provider 接入成本。面试中可强调这一点。

---

## 8. 沙盒文件访问

### 问题

macOS App Sandbox 限制应用只能访问用户明确选择的文件或特定目录。

### 解决方案

- 申请 `com.apple.security.files.user-selected.read-write`。
- 文件引用基于当前文档目录，避免越界。
- 对路径做标准化和范围校验。

### 经验

如果应用要访问更多文件，可以引导用户使用「打开文件」对话框，获得 security-scoped bookmark 后持久化访问权限。
