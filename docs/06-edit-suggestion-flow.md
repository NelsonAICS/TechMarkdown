# 修改建议与确认流程

## 1. 为什么需要确认流程？

AI 对文档的修改可能不符合用户预期，直接覆盖会导致数据丢失。TechMarkdown 采用「建议 → 预览 → 确认」的闭环：

1. AI 生成建议的完整 Markdown 文本。
2. 用户看到 Diff 预览。
3. 用户点击「应用」后，文本才写入编辑器。
4. 用户可随时「拒绝」取消。

## 2. PendingEdit 模型

```swift
// Models/ChatMessage.swift
struct PendingEdit: Identifiable {
    let id = UUID()
    var originalText: String
    var suggestedText: String
    var reason: String
}
```

- `originalText`：修改前的文档内容。
- `suggestedText`：AI 建议的完整新内容。

## 3. Diff 预览

当前版本实现了一个行级 Diff（`Utils/DiffAlgorithm.swift`）：

```swift
func computeLineDiff(oldText: String, newText: String) -> [DiffLine]
```

显示规则：

- 删除行：红色背景
- 新增行：绿色背景
- 未变行：透明背景

`DiffView` 以双栏形式展示当前文档和对比文档，方便用户逐行检查。

## 4. 应用修改

```swift
// Services/AIAgent.swift
func applyPendingEdit(to text: inout String) {
    guard let edit = pendingEdit else { return }
    text = edit.suggestedText
    pendingEdit = nil
}

func discardPendingEdit() {
    pendingEdit = nil
}
```

`inout` 参数让调用方可以直接修改 SwiftUI 状态变量，触发界面刷新。

## 5. 撤销支持

由于修改尚未写入文档，「拒绝」即放弃建议，无需 Undo 栈。若用户已应用修改，编辑器本身支持 `Command+Z` 撤销。

## 6. 与工具调用结合

`apply_markdown_edit` 工具会发送通知：

```swift
// Services/ToolRegistry.swift
NotificationCenter.default.post(
    name: .pendingMarkdownEdit,
    object: nil,
    userInfo: ["markdown": markdown, "reason": reason]
)
```

`AIAgent` 订阅通知并创建 `PendingEdit`：

```swift
// Services/AIAgent.swift
private func observePendingEditNotification() {
    NotificationCenter.default.addObserver(
        forName: .pendingMarkdownEdit,
        object: nil,
        queue: .main
    ) { [weak self] notification in
        guard let markdown = notification.userInfo?["markdown"] as? String,
              let reason = notification.userInfo?["reason"] as? String else { return }
        
        let currentText = UserDefaults.standard.string(forKey: "techmarkdown.currentDocumentText") ?? ""
        self?.pendingEdit = PendingEdit(
            originalText: currentText,
            suggestedText: markdown,
            reason: reason
        )
    }
}
```

`AISidebarView` 展示修改摘要和「查看差异 / 放弃 / 应用」按钮。

## 7. 面试常见问题

**Q: 为什么不用直接替换文档？**

A: 直接替换风险高，用户可能不满意 AI 的修改。确认流程符合人类-in-the-loop 设计，让用户保留最终决策权。

**Q: 如果 AI 只修改了一小部分，如何避免显示整个文档的 Diff？**

A: 未来可以优化 Diff 算法，只显示变更片段。当前版本显示全文 Diff，但可以接受，因为 Markdown 文档通常不会太长。

**Q: 修改应用到文档后如何撤销？**

A: TechMarkdown 主编辑器本身支持 Command+Z 撤销。AI 修改只是替换了编辑器文本，会被纳入编辑器自带的 Undo 管理。
