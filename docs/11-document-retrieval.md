# 项目文件浏览器与文档检索（RAG）

## 概述

TechMarkdown 在左侧边栏新增「项目/文件浏览器」，允许用户将本地项目目录加入应用，浏览项目树、打开文件、将文件或文件夹加入 AI 对话上下文，并基于本地索引对项目文档进行关键词/TF-IDF 混合检索。

## 已安装技能

项目目录 `skills/` 下已安装以下技能，用于辅助文档解析与语义检索：

| 技能 | 版本 | 用途 |
|------|------|------|
| `pdf` | 0.1.0 | PDF 文本/表格提取指南（pypdf/pdfplumber） |
| `docx-anthropic` | 1.0.0 | Word 文档读取/编辑指南（pandoc/python-docx） |
| `semantic-search` | 1.0.0 | 企业级语义检索（表格/字段/文件/Text-to-SQL） |
| `memory-semantic-search` | 1.0.0 | 基于 embedding API + SQLite 的本地 Markdown 语义搜索 |

当前实现主要使用 `pdf` 与 `docx-anthropic` 技能提到的 Python 库（`pypdf`、`python-docx`）通过子进程解析 PDF/DOCX；语义检索当前以本地 TF-IDF 为主，向量检索作为可选扩展点预留。

## 核心组件

### ProjectManager

路径：`TechMarkdown/Services/ProjectManager.swift`

职责：
- 维护一个或多个「项目根目录」。
- 使用 `com.apple.security.files.bookmarks.app-scope` 创建 security-scoped bookmark，持久化到 `UserDefaults`。
- 在访问文件前后调用 `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`。
- 将每个根目录的直接子目录视为一个项目；如无子目录，则将根目录本身视为项目。
- 递归枚举项目内文件/目录（默认最大深度 2）。
- 安全读取文本文件内容。

关键 API：
- `addProjectRoot(_:)`
- `removeProjectRoot(_:)`
- `listProjects()`
- `listFiles(in:maxDepth:)`
- `listFiles(inDirectory:maxDepth:)`
- `readFile(at:maxLength:)`

### ProjectBrowserView

路径：`TechMarkdown/Views/ProjectBrowserView.swift`

职责：
- 左侧边栏项目树 UI。
- 支持通过系统文件选择器（`fileImporter`）添加项目根目录。
- 展开/折叠项目，显示文件/目录。
- 对文件：「打开」（使用 `NSDocumentController`）、「加入对话上下文」。
- 对文件夹：「将文件夹下文件加入对话上下文」（默认递归深度 2，最多 20 个文件）。

### DocumentRetrievalService

路径：`TechMarkdown/Services/DocumentRetrievalService.swift`

职责：
- 根据扩展名提取文件纯文本：
  - 文本/Markdown/代码：直接读取。
  - PDF：调用 `pypdf`（Python 子进程）。
  - DOCX：调用 `python-docx`（Python 子进程）。
- 将文档分块（默认 1000 字符、重叠 100 字符）。
- 构建本地 TF-IDF 倒排索引和文档向量。
- 提供关键词命中 + 余弦相似度混合检索。

关键 API：
- `extractText(from:maxLength:)`
- `chunk(text:path:chunkSize:overlap:)`
- `indexProject(_:)` / `indexProjects(_:)` / `indexAllProjects()`
- `search(query:topK:)`

### 新增工具

注册于 `TechMarkdown/Services/ToolRegistry.swift`：

| 工具 | 说明 |
|------|------|
| `list_project_files` | 列出项目文件/目录，或返回所有项目根目录 |
| `read_project_file` | 读取项目内文件内容，自动解析 PDF/DOCX |
| `add_project_file_to_context` | 将项目文件加入当前 AI 对话上下文 |
| `query_project_documents` | 基于本地索引对项目文档进行混合检索 |

`add_project_file_to_context` 通过 `NotificationCenter` 通知 `AIAgent`，由 `AIAgent.addProjectFileToContext(path:)` 使用 `DocumentRetrievalService` 读取内容并加入 `referencedFiles`。

## 索引与检索流程

1. 用户通过项目浏览器添加项目根目录（创建 app-scoped bookmark）。
2. 应用调用 `DocumentRetrievalService.indexAllProjects()` 或 `indexProject(_:)` 构建索引：
   - 枚举项目内可索引文件。
   - 提取文本并分块。
   - 基于词频构建 TF-IDF 向量。
3. 用户或 AI 调用 `query_project_documents` 时：
   - 对查询分词，计算查询向量。
   - 关键词命中获得初始权重。
   - 与文档向量计算余弦相似度。
   - 合并分数，返回 Top-K 结果及摘要片段。

## 沙盒权限

`TechMarkdown/TechMarkdown.entitlements` 已添加：

```xml
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

配合已有的 `files.user-selected.read-write`，实现对用户选定项目目录的跨启动持久访问。

## 后续扩展

- **向量索引**：可接入 `memory-semantic-search` 技能的 embedding API 与 SQLite 向量存储，将分块向量化后实现语义检索。
- **增量索引**：监听项目文件变更，仅对新增/修改文件重新索引。
- **更大文件支持**：对 PDF/DOCX 进行分页/分块流式提取，避免一次性加载大文件。
- **检索结果高亮**：在编辑器中打开结果文件并定位到匹配片段。
