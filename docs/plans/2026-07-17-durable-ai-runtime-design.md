# TechMarkdown 持久化 AI 运行时设计

## 目标

TechMarkdown 的 AI 助手定位为本地文档、知识阅读与研究 Agent。一次运行必须可观察、可取消、可恢复；文档修改必须确认且只能应用一次；应用重启后，用户仍能按项目和文件找到对话并继续原有上下文。

## 核心模型

```
ConversationThread
├── messages
├── persisted context
└── AgentRun
    ├── lifecycle status
    ├── checkpoint
    └── RunStep[]
        ├── context
        ├── intent
        ├── generation summary
        ├── tool call/result
        ├── approval
        └── error
```

- `Conversation` 是持久化线程，绑定稳定 `threadID`、主文件路径和引用文件。
- `AgentRunRecord` 表示一次用户请求，保存检查点消息数量、父运行、错误和生命周期。
- `AgentRunStep` 是面向用户的语义步骤。原始 token 只用于流式显示，不写入数据库。
- `PendingEdit` 具有稳定 ID。SQLite 中的应用记录形成幂等屏障。

## 生命周期

```
preparing → retrieving → generating → executingTool → generating
                                  ↘ awaitingApproval
generating → finalizing → completed
任意活动状态 → cancelled / failed / interrupted
failed / interrupted → 新建 child run，从安全检查点恢复
```

约束：

- 每次运行最多 8 次模型请求、12 次工具调用。
- 工具按模型给出的顺序执行，避免有副作用的工具并发。
- 每个网络流和工具前检查取消状态。
- 应用启动时把遗留的活动运行标记为 `interrupted`。
- 恢复不会续接已断开的 SSE，而是回到运行开始时的消息检查点，新建关联运行。

## 持久化

使用 Application Support 下的 SQLite 数据库，WAL 模式：

- `conversations`：消息和文件上下文；
- `agent_runs`：运行生命周期与恢复检查点；
- `run_steps`：可重放的用户可见步骤；
- `applied_edits`：文档修改幂等记录。

旧版 `Conversations/*.json` 在首次启动时导入，成功后保留原文件，不做破坏性删除。

## 文档修改安全

1. AI 工具只能产生 `PendingEdit`，不能直接覆盖正文。
2. 用户选择差异块并确认。
3. 应用前比较当前正文与建议基线；正文已变化时阻止应用。
4. 查询 `applied_edits`；同一编辑已应用时直接拒绝。
5. 创建修改前版本、应用差异、记录应用凭据，再创建修改后版本。

## UI

视觉方向为原生、克制的研究工作台：

- 当前运行显示为时间线；
- 成功步骤自动折叠，失败、审批和执行中步骤保持展开；
- “思考过程”改为“过程摘要”，不展示或持久化原始思维链；
- 当前文件的历史对话优先显示，也可切换全部对话；
- 失败或中断运行显示“从安全检查点恢复”；
- 文件内容变化时显示上下文更新提示。

## 非功能要求

- 流式 token 不触发数据库逐 token 写入。
- 数据库写入使用事务和预编译语句，失败不能破坏已有对话。
- 对话保存后重启可恢复，RPO 为最后一个语义步骤。
- 本地文件内容、对话和运行步骤默认不上传第三方；只有组装后的模型请求会发送给用户配置的服务商。

## 失败模式

| 失败 | 处理 |
|---|---|
| 网络中断 | 运行标记失败，保留错误和检查点 |
| 应用退出 | 下次启动标记中断，可恢复 |
| SQLite 写入失败 | 保持内存状态并向用户显示持久化错误 |
| 文件移动或修改 | 使用文件路径与内容指纹检测，提示重新建立上下文 |
| 重复应用编辑 | 幂等表拒绝，不修改正文 |
| 工具循环失控 | 达到轮次或工具上限后失败并说明原因 |

