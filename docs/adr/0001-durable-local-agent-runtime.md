# ADR-0001: 使用 SQLite 持久化本地 Agent 运行时

## Status

Accepted

## Context

现有对话按 JSON 文件保存，工具和推理事件只存在内存，文档版本存在全局 UserDefaults。它们无法可靠表达线程、运行、步骤、文件上下文和修改应用之间的关系，也无法支持应用重启后的失败恢复。

TechMarkdown 是单用户 macOS 本地应用，不需要分布式服务，但需要事务、查询、迁移和崩溃恢复。

## Decision

采用“内存状态机 + SQLite 语义检查点”的混合架构：

- SwiftUI 只观察内存中的 `AIAgent`；
- `AgentRunRecord` 驱动明确生命周期；
- 原始流事件归并为 `AgentRunStep`；
- Conversation、Run、Step 和 AppliedEdit 写入本地 SQLite；
- 不把原始 token 事件作为永久事实源。

## Consequences

### Positive

- 可以按文件检索对话并跨重启继续。
- 可以恢复失败和中断运行。
- 工具步骤、审批和错误可重放。
- 修改应用具有事务化幂等记录。
- 不引入第三方数据库依赖。

### Negative

- 需要维护 SQLite schema 和迁移代码。
- 运行时模型比原来的消息数组更复杂。
- 旧 JSON 历史需要兼容导入。

### Neutral

- 流式 token 仍保留在内存，最终文本和语义步骤才持久化。

## Alternatives Considered

### 继续扩展 JSON 文件

实现简单，但跨线程查询、步骤更新和幂等记录容易产生部分写入，不适合作为长期运行时存储。

### SwiftData

与 SwiftUI 集成好，但会把持久化对象直接渗透到视图和运行时；现阶段需要保留清晰的仓储边界和可测试的 Codable 模型。

### 完整事件溯源

能够重放所有 token，但数据量、迁移和调试成本对单机文档应用过高。

