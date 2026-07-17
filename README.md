# TechMarkdown

一款 macOS 原生 Markdown 预览 / 编辑器，采用科技风 UI，支持双栏编辑、实时预览、LaTeX 公式、代码高亮、主题切换、页面缩放、文件对比，以及 **AI Agent 智能助手**。

## 功能特性

- **原生 macOS 应用**：基于 SwiftUI + AppKit + WKWebView 构建
- **文件关联**：右键 `.md` / `.markdown` 文件可选择用 TechMarkdown 打开
- **实时预览**：左侧编辑，右侧即时渲染 Markdown
- **LaTeX 公式支持**：行内 `$...$` 与独立 `$$...$$` 均可渲染
- **代码高亮**：基于 highlight.js，支持 Swift、Python、JavaScript、Bash、JSON、C++ 等
- **科技风主题**：暗色 / 亮色两套主题，支持一键切换（⌘⇧T）
- **页面缩放**：预览区支持放大 / 缩小 / 重置（⌘+ / ⌘- / ⌘0）
- **文档统计**：侧边栏显示字符数、词数、行数
- **文件对比**：可将当前文档与另一个 Markdown 文件进行行级差异对比（⌘⇧D）
- **批注审阅**：对编辑器或预览中的选区添加批注，支持重定位、筛选、解决状态与 AI 汇总优化
- **编辑设置**：可调整编辑器字体大小
- **AI 智能助手**：对当前文档提问、获取修改建议、引用本地文件、使用 Skill 快捷任务、Tool Use / MCP 扩展

## 系统要求

- macOS 14.0 或更高版本
- Swift 5.10 或更高版本
- Xcode 15.0 或更高版本（推荐，用于界面预览和打包）
- 需要网络连接以调用大模型 API 并加载 KaTeX、marked、highlight.js 等预览渲染库

## 如何运行与安装

### 方式一：Swift Package Manager（推荐用于快速编译验证）

```bash
cd /Users/nelson/Desktop/TechMarkdown
swift build
```

### 方式二：Xcode

```bash
cd /Users/nelson/Desktop/TechMarkdown
xcodegen generate  # 若 .xcodeproj 需要更新
open TechMarkdown.xcodeproj
```

然后在 Xcode 中选择目标设备为 **My Mac**，点击运行按钮（⌘R）。

> 首次运行若提示需要网络权限，请允许，因为预览渲染依赖 CDN 加载 KaTeX、marked、highlight.js。

### 安装到“应用程序”

1. 使用 Xcode 打开 `TechMarkdown.xcodeproj`，运行目标选择 **My Mac**。
2. 在 `Product → Scheme → Edit Scheme… → Run → Build Configuration` 中选择 **Release**。
3. 执行 `Product → Build`（⌘B）。
4. 在 Xcode 左侧的 **Products** 中找到 `TechMarkdown.app`，右键选择 **Show in Finder**。
5. 将 `TechMarkdown.app` 拖入 Finder 的 **应用程序（Applications）** 文件夹。
6. 第一次打开若被 macOS 拦截，进入 **系统设置 → 隐私与安全性**，确认打开该应用。

也可以在终端中构建 Release 版本：

```bash
cd /Users/nelson/Desktop/TechMarkdown
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project TechMarkdown.xcodeproj \
  -scheme TechMarkdown \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build build
```

构建结果位于：

```text
build/Build/Products/Release/TechMarkdown.app
```

当前工程使用本地开发签名，适合在自己的 Mac 上安装。若要分发给其他用户，需要先把 `com.example.TechMarkdown` 更换为正式 Bundle ID，并完成 Developer ID 签名和 Apple 公证。

## 如何设置为 `.md` 默认打开方式

1. 在 Finder 中右键任意 `.md` 文件
2. 选择 **显示简介**（Get Info）
3. 在 **打开方式**中选择 **TechMarkdown**
4. 点击 **全部更改**，即可将所有 `.md` 文件默认用 TechMarkdown 打开

## 项目结构

```
TechMarkdown/
├── Package.swift                   # Swift Package Manager 配置
├── TechMarkdown.xcodeproj          # Xcode 工程
├── project.yml                     # XcodeGen 项目配置
├── TechMarkdown/
│   ├── TechMarkdownApp.swift       # App 入口与菜单命令
│   ├── Models/
│   │   ├── MarkdownDocument.swift  # 文件文档模型
│   │   ├── ChatMessage.swift       # AI 对话消息模型
│   │   ├── AIProvider.swift        # AI Provider 配置
│   │   ├── Skill.swift             # Skill 定义
│   │   ├── Tool.swift              # Tool 定义
│   │   └── ThemeManager.swift      # 主题 / 缩放状态管理
│   ├── Views/
│   │   ├── ContentView.swift       # 主界面
│   │   ├── EditorView.swift        # Markdown 编辑器
│   │   ├── PreviewView.swift       # WKWebView 实时预览
│   │   ├── DiffView.swift          # 双栏文件对比视图
│   │   ├── AISidebarView.swift     # AI 问答侧边栏
│   │   └── AISettingsView.swift    # AI 配置面板
│   ├── Services/
│   │   ├── AIService.swift         # OpenAI 兼容 API 调用
│   │   ├── AIAgent.swift           # AI Agent 协调器
│   │   ├── ToolRegistry.swift      # 内置工具注册与执行
│   │   ├── FileContextService.swift# 本地文件引用解析
│   │   ├── MarkdownEditService.swift# Markdown 修改提取
│   │   ├── KeychainService.swift   # API Key 安全存储
│   │   └── MCPClient.swift         # MCP 客户端协议与管理
│   ├── Utils/
│   │   └── DiffAlgorithm.swift     # 行级 diff 算法
│   ├── Resources/
│   │   └── preview-template.html   # 预览 HTML 模板
│   ├── Info.plist                  # 文件类型声明
│   └── TechMarkdown.entitlements   # 沙盒与网络权限
└── docs/                           # 详细项目文档（面试用）
```

## AI Agent 功能

- **AI 问答侧边栏**：对当前 Markdown 文档提问，支持多轮对话。
- **独立批注工作区**：在“对话 / 批注”之间切换，集中处理选区批注和全文意见。
- **修改建议与确认**：AI 生成修改后，用户可在 Diff 预览中确认或放弃。
- **本地文件引用**：输入 `@~/Documents/note.md` 或拖拽文件，AI 会结合文件内容回答。
- **Skill 快捷任务**：总结、润色、翻译、解释、生成目录等一键执行。
- **Tool Use / Function Calling**：内置 read_file、list_directory、search_in_document、apply_markdown_edit 工具。
- **MCP 扩展**：可接入外部 MCP Server，扩展 AI 能力。

详细的架构设计、技术决策、问题与解决方案、面试问答请见 [`docs/`](docs/) 目录。

## 键盘快捷键

| 快捷键 | 功能 |
|---|---|
| ⌘⇧T | 切换暗色 / 亮色主题 |
| ⌘+ | 放大预览 |
| ⌘- | 缩小预览 |
| ⌘0 | 重置预览缩放 |
| ⌘⇧D | 打开文件对比面板 |

## 技术说明

- 编辑器使用 SwiftUI `TextEditor`
- 预览使用 `WKWebView` 加载本地 HTML 模板，通过 `evaluateJavaScript` 注入 Markdown 文本
- Markdown 解析使用 [marked.js](https://marked.js.org/)
- 数学公式渲染使用 [KaTeX](https://katex.org/)
- 代码高亮使用 [highlight.js](https://highlightjs.org/)
- 文件对比使用简单的 LCS（最长公共子序列）行级 diff 算法
- AI 调用使用 OpenAI 兼容协议，支持 OpenAI、Gemini、豆包、通义千问及自定义 Provider

## 许可证

MIT License — 可自由修改与分发。
