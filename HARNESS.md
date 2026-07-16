# TechMarkdown Harness 开发手册

> 本文档定义本项目的测试约束、边界、验收标准与系统性优化路径。所有新功能与 bugfix 必须遵循 TDD（测试先行）流程。

---

## 1. 为什么需要 Harness

当前项目存在以下测试债务：

- `Package.swift` 没有 `testTarget`。
- `project.yml` 没有测试 target。
- 代码库约 12,500 行 Swift，无任何自动化测试。
- 核心逻辑（Diff 算法、文档格式判断、记忆服务、文件索引）完全依赖手动验证。

本手册的目标是把“测试是最后一步”改成“测试是第一步”，并为持续集成建立最小可运行基线。

---

## 2. 约束（Constraints）

### 2.1 必须测试的代码

| 类别 | 说明 | 示例 |
|---|---|---|
| **纯函数 / 算法** | 输入输出确定、无副作用 | `computeLineDiff`、`markdownHeadingSlug`、hex 颜色解析 |
| **模型序列化** | Codable、FileDocument 读写 | `MarkdownDocument`、`FileIndexEntry`、`UserProfileMemory` |
| **格式判断** | 根据文件扩展名/内容判断类型 | `DocumentFormat.forURL` |
| **核心服务逻辑** | 可被隔离测试的业务规则 | `MemoryService` 的文件索引增删改查 |
| **UI 状态转换** | 视图在不同输入下的行为 | `ContentView.showLaunchScreen` 的显示/隐藏规则 |

### 2.2 允许不测试的代码

- SwiftUI 视图的布局细节（通过预览与手动验收）。
- 仅做桥接的 AppKit/WKWebView 包装代码。
- 需要真实网络或大模型 API 的调用（应通过协议抽取接口后测试 mock）。

### 2.3 测试运行约束

- 使用 `swift test` 作为本地与 CI 的统一入口。
- 测试必须在 **macOS 14.0+** 上运行。
- 测试不能写入真实 `~/Library/Application Support/com.example.TechMarkdown`，必须使用临时目录。
- 测试不能依赖真实 UserDefaults 持久化状态，必须使用注入的内存存储或独立 suite。

---

## 3. 边界（Boundaries）

### 3.1 测试目标边界

```
┌─────────────────────────────────────────────────────────────┐
│  必须测试（高价值、低风险）                                  │
│  - DiffAlgorithm                                            │
│  - MarkdownDocument 读写                                    │
│  - DocumentFormat                                           │
│  - String+Slug / Color+Hex                                  │
│  - MemoryService（注入临时目录）                              │
├─────────────────────────────────────────────────────────────┤
│  推荐测试（中等价值）                                        │
│  - UserProfileMemory.promptSection                          │
│  - ProjectManager 书签管理（需要可重置的测试模式）            │
│  - IntentRecognitionService 规则分类                        │
├─────────────────────────────────────────────────────────────┤
│  暂缓 / 隔离测试（高成本或需重构）                            │
│  - AIAgent / AIService（依赖网络与 LLM）                     │
│  - EditorView / PreviewView（依赖 AppKit/WKWebView）         │
│  - 完整 UI 流程（需要 XCUITest 或人工验收）                   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 架构边界

- **视图层（Views）**：不直接测试 body 输出，而是把业务逻辑下沉到 `*Service` 或 `*State`。
- **服务层（Services）**：通过依赖注入或 testable init 提供可替换的存储/网络边界。
- **工具层（Utils）**：全部视为纯函数，100% 覆盖。

### 3.3 外部依赖边界

| 依赖 | 真实实现 | 测试中替代方案 |
|---|---|---|
| `UserDefaults` | 应用配置持久化 | 注入 `UserDefaults(suiteName:)` 或内存字典 |
| `Application Support` 目录 | 记忆/对话/索引文件 | 注入临时 `URL` |
| 网络 API | OpenAI 兼容接口 | 创建 `AIServiceProtocol` + mock |
| Keychain | API Key 安全存储 | 当前使用 UserDefaults，需迁移到真实 Keychain 后再抽象 |

---

## 4. 验收标准（Acceptance Criteria）

### 4.1 每次提交前必须通过

- [ ] `swift build` 成功，无 error。
- [ ] `swift test` 成功，所有测试通过。
- [ ] 新增功能必须伴随对应测试（TDD）。
- [ ] 修改既有功能时，先写失败测试再修复（回归保护）。

### 4.2 覆盖率目标（逐步提升）

| 阶段 | 目标 | 时间节点 |
|---|---|---|
| Phase 1 | Utils + Models 核心逻辑 ≥ 80% | 当前迭代 |
| Phase 2 | Services 可单元测试部分 ≥ 60% | 下一迭代 |
| Phase 3 | 整体行覆盖率 ≥ 50%，关键路径 ≥ 80% | 长期 |

### 4.3 测试质量标准

- **一个测试只验证一个行为**：名称必须清楚表达“在什么情况下，期望什么结果”。
- **不使用真实文件系统/网络**：除非测试目标就是 IO 集成。
- **不使用 sleep**：异步测试使用 `XCTestExpectation` 或 Swift concurrency。
- **测试必须稳定**：禁止 flaky test（如依赖当前时间、随机数未种子化）。

---

## 5. 当前已建立的 Harness 基础设施

### 5.1 测试 Target

- `Package.swift` 增加 `TechMarkdownTests` target。
- `project.yml` 增加 `TechMarkdownTests` target（供 XcodeGen 生成工程）。

### 5.2 可测试化改造

- `MemoryService` 支持通过 `init(directoryURL:)` 注入临时目录，避免污染真实应用数据。
- `ProjectManager` 提供 `resetForTesting()` 方法，便于在测试间清理状态（注意：当前仍依赖真实 UserDefaults，后续需进一步抽象）。

### 5.3 测试文件组织

```
Tests/
└── TechMarkdownTests/
    ├── DiffAlgorithmTests.swift
    ├── MarkdownDocumentTests.swift
    ├── StringSlugTests.swift
    ├── ColorHexTests.swift
    ├── DocumentFormatTests.swift
    ├── UserProfileMemoryTests.swift
    └── MemoryServiceTests.swift
```

---

## 6. 系统性优化路径

### 6.1 短期（本迭代）

1. ✅ 建立 `swift test` 可运行的测试 target。
2. ✅ 为 Utils 与 Models 编写单元测试。
3. ✅ 对 `MemoryService` 做依赖注入改造。
4. 每次 bugfix 先写失败测试。

### 6.2 中期（后续 2~4 周）

1. 为 `ProjectManager` 引入 `BookmarkStorage` 协议，彻底隔离 `UserDefaults`。
2. 为 `AIService` 引入 `LLMClientProtocol`，使 `AIAgent` 可在无网络环境下测试。
3. 为 `IntentRecognitionService` 建立规则分类测试集。
4. 引入 GitHub Actions / CI 运行 `swift build && swift test`。

### 6.3 长期（季度）

1. 建立 UI 测试套件，覆盖启动页 → 打开文件 → 编辑 → 保存 主路径。
2. 引入代码覆盖率工具（如 `llvm-cov` / `slather`）并设置门禁。
3. 逐步把 UserDefaults 中的重数据（版本历史、批注）迁移到 SQLite/文件，降低测试耦合。
4. 引入 Snapshot Testing 或 Perceptual Diff 对预览渲染进行回归测试。

---

## 7. TDD 执行 checklist

每次接到新需求或 bugfix 时：

1. **Red**：写一个失败的测试，验证期望行为。
2. **Verify Red**：运行 `swift test --filter <TestName>`，确认失败原因正确。
3. **Green**：写最小代码使测试通过。
4. **Verify Green**：运行完整测试套件，确认无回归。
5. **Refactor**：在不改变行为的前提下清理代码。
6. **提交**：确保 `swift build && swift test` 全绿。

> 违反以上任意一步，视为未通过 Harness 验收。
