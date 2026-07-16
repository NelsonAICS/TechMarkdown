# 构建与运行

## 1. 环境要求

- macOS 14.0+
- Swift 5.10+
- Xcode 15+（推荐，用于界面预览和打包）
- 或者 Command Line Tools + Swift Package Manager（仅用于编译验证）

## 2. 目录结构

```
TechMarkdown/
├── Package.swift                 # Swift Package Manager 配置
├── TechMarkdown.xcodeproj        # Xcode 工程（由 XcodeGen 生成）
├── project.yml                   # XcodeGen 配置文件
├── TechMarkdown/                 # 主目标源码
│   ├── TechMarkdownApp.swift
│   ├── Models/
│   │   ├── MarkdownDocument.swift
│   │   ├── ChatMessage.swift
│   │   ├── AIProvider.swift
│   │   ├── Skill.swift
│   │   ├── Tool.swift
│   │   └── ThemeManager.swift
│   ├── Services/
│   │   ├── AIService.swift
│   │   ├── AIAgent.swift
│   │   ├── ToolRegistry.swift
│   │   ├── FileContextService.swift
│   │   ├── MarkdownEditService.swift
│   │   ├── KeychainService.swift
│   │   └── MCPClient.swift
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── EditorView.swift
│   │   ├── PreviewView.swift
│   │   ├── DiffView.swift
│   │   ├── AISidebarView.swift
│   │   └── AISettingsView.swift
│   ├── Utils/
│   │   └── DiffAlgorithm.swift
│   └── Resources/
│       └── preview-template.html
└── docs/                         # 项目文档
```

## 3. 使用 Swift Package Manager 编译

```bash
cd /Users/nelson/Desktop/TechMarkdown
swift build
```

成功输出示例：

```
Building for debugging...
[29/30] Applying TechMarkdown
Build complete!
```

> 注意：当前环境只有 Command Line Tools 时，`swift build` 可能会出现 `could not determine XCTest paths` 的警告，但只要不运行测试，编译和链接仍可正常完成。

## 4. 使用 Xcode 运行

```bash
cd /Users/nelson/Desktop/TechMarkdown
xcodegen generate  # 如果 .xcodeproj 不存在或需要更新
open TechMarkdown.xcodeproj
```

然后在 Xcode 中选择 Mac 目标，点击运行。

## 5. 配置 AI Provider

首次运行后：

1. 打开「AI 设置」（工具栏齿轮图标或左侧 AI 功能面板）。
2. 选择 Provider：OpenAI / Gemini / 豆包 / 通义千问 / 自定义。
3. 输入 API Key（会保存到 Keychain）。
4. 点击「测试连接」验证。
5. 在 AI 侧边栏输入问题开始对话。

## 6. 使用 AI 侧边栏

- 切换显示：`工具栏 brain 图标` 或左侧「显示 AI 侧边栏」。
- 普通提问：在输入框输入问题，按发送按钮。
- 引用文件：输入 `@~/Documents/note.md` 或点击回形针选择文件。
- 使用 Skill：点击魔棒图标选择「总结 / 润色 / 翻译 / 解释 / 生成目录」。
- 应用修改：当 AI 建议修改时，侧边栏会显示 Diff 摘要，点击「应用」后文档内容更新。

## 7. 添加 MCP Server

1. 打开「AI 设置 → 管理 MCP 扩展」。
2. 输入名称和端点 URL（例如 `http://127.0.0.1:8000`）。
3. 选择传输协议（当前仅 HTTP 完整实现）。
4. 点击「添加」后，点击「连接全部」。
5. 如果连接成功，发现的工具会自动加入 LLM 可用工具列表。

## 8. 常见问题

**Q: `swift build` 提示找不到 Package.swift？**

A: 确保在 TechMarkdown 根目录执行命令，而不是 `TechMarkdown/TechMarkdown` 子目录。

**Q: `xcodebuild` 报错 `active developer directory ... is a command line tools instance`？**

A: 当前环境缺少完整 Xcode。请使用 `swift build` 进行编译验证，或在安装了完整 Xcode 的机器上运行。

**Q: 运行时无法访问网络？**

A: 检查 `TechMarkdown.entitlements` 中是否包含 `com.apple.security.network.client`。

**Q: 无法读取本地文件？**

A: 检查 `TechMarkdown.entitlements` 中是否包含 `com.apple.security.files.user-selected.read-write`，并确保用户通过文件选择器授权。
