# Durable AI Runtime Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a durable local document-agent runtime whose visible steps, cancellation, recovery, edit approvals, file-scoped conversations, and context survive app restarts.

**Architecture:** Keep streaming UI state in `AIAgent`, reduce provider events into Codable run records and semantic steps, and persist conversations/runs/steps/edit receipts in SQLite. Resume failed runs from a persisted message-count checkpoint instead of attempting to resume a broken network stream.

**Tech Stack:** Swift 5.10, SwiftUI Observation, Foundation, SQLite3, XCTest.

---

### Task 1: Runtime domain model

**Files:**
- Create: `TechMarkdown/Models/AgentRuntime.swift`
- Modify: `TechMarkdown/Models/Conversation.swift`
- Modify: `TechMarkdown/Models/ChatMessage.swift`
- Test: `Tests/TechMarkdownTests/AgentRuntimeTests.swift`

**Steps:**
1. Write tests for lifecycle terminal/recoverable states, step expansion defaults, context fingerprints, and backwards-compatible conversation decoding.
2. Run the focused tests and confirm they fail because the models do not exist.
3. Implement Codable `AgentRunRecord`, `AgentRunStep`, `ConversationContext`, status enums, and stable edit identity.
4. Run focused tests and confirm they pass.

### Task 2: SQLite workspace store

**Files:**
- Rewrite: `TechMarkdown/Services/ConversationHistoryService.swift`
- Test: `Tests/TechMarkdownTests/ConversationHistoryServiceTests.swift`

**Steps:**
1. Write tests using a temporary database for conversation round-trip, file filtering, run/step persistence, startup interruption, and edit idempotency.
2. Run focused tests and confirm failure.
3. Add SQLite schema, WAL configuration, prepared bindings, atomic writes, and legacy JSON import.
4. Run focused tests and confirm pass.

### Task 3: Iterative agent lifecycle

**Files:**
- Modify: `TechMarkdown/Services/AIAgent.swift`
- Modify: `TechMarkdown/Services/ToolRegistry.swift`
- Modify: `TechMarkdown/Models/Tool.swift`
- Test: `Tests/TechMarkdownTests/AgentRuntimeTests.swift`

**Steps:**
1. Add tests for loop limits, sequential tool policy, cancellation transitions, and recovery checkpoints.
2. Replace recursive `executeStreamingRound` with a bounded iterative loop.
3. Persist run status and semantic steps at each safe boundary.
4. Add resume from failed/interrupted run and ensure cancellation is not overwritten by finalization.
5. Run focused tests.

### Task 4: Approved and idempotent edits

**Files:**
- Modify: `TechMarkdown/Models/ChatMessage.swift`
- Modify: `TechMarkdown/Services/AIAgent.swift`
- Modify: `TechMarkdown/Services/VersionHistoryService.swift`
- Test: `Tests/TechMarkdownTests/AgentRuntimeTests.swift`

**Steps:**
1. Test stale-base rejection and duplicate edit receipt rejection.
2. Persist pending edit in conversation context.
3. Check current content fingerprint and edit receipt before applying.
4. Link before/after versions to file, conversation, run, and edit.
5. Run focused tests.

### Task 5: Run timeline and recovery UI

**Files:**
- Create: `TechMarkdown/Views/AgentRunTimelineView.swift`
- Modify: `TechMarkdown/Views/AISidebarView.swift`
- Modify: `TechMarkdown/Views/ContentView.swift`

**Steps:**
1. Add current-run timeline with accessible status labels.
2. Auto-collapse completed steps; keep running, failed, and approval steps open.
3. Replace raw reasoning label with privacy-safe process summary.
4. Add recovery banner and resume action.
5. Throttle streaming scroll/Markdown refresh behavior.

### Task 6: File-scoped conversation continuation

**Files:**
- Modify: `TechMarkdown/Services/AIAgent.swift`
- Modify: `TechMarkdown/Views/AISidebarView.swift`
- Modify: `TechMarkdown/Views/ContentView.swift`
- Test: `Tests/TechMarkdownTests/ConversationHistoryServiceTests.swift`

**Steps:**
1. Save stable thread ID, primary file path, references, and document fingerprint.
2. Filter history by current file and retain an all-conversations view.
3. Restore references, thread ID, pending approval, run steps, and context notices.
4. Continue with the current document plus persisted recent messages and references.

### Task 7: Integration verification

**Files:**
- Modify: `README.md`
- Modify: `docs/02-ai-agent-integration.md`
- Modify: `docs/05-memory-and-context.md`
- Modify: `docs/10-ag-ui-protocol.md`

**Steps:**
1. Regenerate the Xcode project so new source and test files are included.
2. Run `swift test --disable-sandbox` and require zero failures.
3. Build the macOS target with Xcode.
4. Launch the app and verify running, completed, failed, cancelled, approval, reload, and resume states visually.
5. Update documentation with implemented behavior and known limits.

