import Foundation
import SQLite3

/// Conversation、Agent Run、语义步骤和修改回执的本地持久化仓库。
///
/// 原始 token 不写入数据库；只有完成的消息和安全检查点会持久化。
final class ConversationHistoryService {
    static let shared: ConversationHistoryService = {
        do {
            return try ConversationHistoryService(
                databaseURL: defaultDatabaseURL,
                legacyDirectoryURL: defaultLegacyDirectoryURL
            )
        } catch {
            fatalError("无法初始化对话数据库: \(error.localizedDescription)")
        }
    }()

    private static var supportDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.example.TechMarkdown", isDirectory: true)
    }

    private static var defaultDatabaseURL: URL {
        supportDirectoryURL.appendingPathComponent("Workspace.sqlite")
    }

    private static var defaultLegacyDirectoryURL: URL {
        supportDirectoryURL.appendingPathComponent("Conversations", isDirectory: true)
    }

    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let databaseURL: URL
    private let legacyDirectoryURL: URL?

    init(databaseURL: URL, legacyDirectoryURL: URL? = nil) throws {
        self.databaseURL = databaseURL
        self.legacyDirectoryURL = legacyDirectoryURL

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(database)
            database = nil
            throw StoreError.openFailed(message)
        }

        try configureDatabase()
        try createSchema()
        try migrateLegacyConversationsIfNeeded()
        try markActiveRunsInterrupted()
    }

    deinit {
        sqlite3_close(database)
    }

    // MARK: - Conversation

    func save(_ conversation: Conversation) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let messages = try encoder.encode(conversation.messages)
            let context = try encoder.encode(conversation.context)
            let sql = """
                INSERT INTO conversations (
                    id, thread_id, title, created_at, updated_at,
                    primary_file_path, project_root_path, messages_json, context_json,
                    is_pinned, is_archived
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    thread_id = excluded.thread_id,
                    title = excluded.title,
                    updated_at = excluded.updated_at,
                    primary_file_path = excluded.primary_file_path,
                    project_root_path = excluded.project_root_path,
                    messages_json = excluded.messages_json,
                    context_json = excluded.context_json,
                    is_pinned = excluded.is_pinned,
                    is_archived = excluded.is_archived
                """
            try withStatement(sql) { statement in
                bind(conversation.id.uuidString, at: 1, to: statement)
                bind(conversation.threadID, at: 2, to: statement)
                bind(conversation.title, at: 3, to: statement)
                sqlite3_bind_double(statement, 4, conversation.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 5, conversation.updatedAt.timeIntervalSince1970)
                bind(conversation.context.primaryFilePath, at: 6, to: statement)
                bind(conversation.context.projectRootPath, at: 7, to: statement)
                bind(messages, at: 8, to: statement)
                bind(context, at: 9, to: statement)
                sqlite3_bind_int(statement, 10, conversation.isPinned ? 1 : 0)
                sqlite3_bind_int(statement, 11, conversation.isArchived ? 1 : 0)
                try stepDone(statement)
            }
        } catch {
            assertionFailure("保存对话失败: \(error.localizedDescription)")
        }
    }

    func list() -> [Conversation] {
        queryConversations(
            sql: """
                SELECT id, thread_id, title, created_at, updated_at,
                       messages_json, context_json, is_pinned, is_archived
                FROM conversations
                ORDER BY is_pinned DESC, updated_at DESC
                """
        )
    }

    func list(forFilePath path: String) -> [Conversation] {
        let normalizedPath = Self.normalize(path)
        return queryConversations(
            sql: """
                SELECT id, thread_id, title, created_at, updated_at,
                       messages_json, context_json, is_pinned, is_archived
                FROM conversations
                WHERE primary_file_path = ?
                ORDER BY is_pinned DESC, updated_at DESC
                """,
            bindValues: [normalizedPath]
        )
    }

    func load(id: UUID) -> Conversation? {
        queryConversations(
            sql: """
                SELECT id, thread_id, title, created_at, updated_at,
                       messages_json, context_json, is_pinned, is_archived
                FROM conversations
                WHERE id = ?
                LIMIT 1
                """,
            bindValues: [id.uuidString]
        ).first
    }

    func delete(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? withStatement("DELETE FROM conversations WHERE id = ?") { statement in
            bind(id.uuidString, at: 1, to: statement)
            try stepDone(statement)
        }
    }

    func generateTitle(from messages: [ChatMessage]) -> String {
        guard let firstUserMessage = messages.first(where: { $0.role == .user }) else {
            return "未命名对话"
        }
        let content = firstUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(content.prefix(24))
        return prefix.isEmpty ? "未命名对话" : prefix
    }

    // MARK: - Runs

    func saveRun(_ run: AgentRunRecord) {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
            INSERT INTO agent_runs (
                id, conversation_id, thread_id, parent_run_id, status,
                checkpoint_message_count, model_round_count, tool_call_count,
                started_at, updated_at, ended_at, error_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                status = excluded.status,
                model_round_count = excluded.model_round_count,
                tool_call_count = excluded.tool_call_count,
                updated_at = excluded.updated_at,
                ended_at = excluded.ended_at,
                error_message = excluded.error_message
            """
        do {
            try withStatement(sql) { statement in
                bind(run.id.uuidString, at: 1, to: statement)
                bind(run.conversationID.uuidString, at: 2, to: statement)
                bind(run.threadID, at: 3, to: statement)
                bind(run.parentRunID?.uuidString, at: 4, to: statement)
                bind(run.status.rawValue, at: 5, to: statement)
                sqlite3_bind_int(statement, 6, Int32(run.checkpointMessageCount))
                sqlite3_bind_int(statement, 7, Int32(run.modelRoundCount))
                sqlite3_bind_int(statement, 8, Int32(run.toolCallCount))
                sqlite3_bind_double(statement, 9, run.startedAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 10, run.updatedAt.timeIntervalSince1970)
                bind(run.endedAt?.timeIntervalSince1970, at: 11, to: statement)
                bind(run.errorMessage, at: 12, to: statement)
                try stepDone(statement)
            }
        } catch {
            assertionFailure("保存 Agent Run 失败: \(error.localizedDescription)")
        }
    }

    func loadRuns(conversationID: UUID) -> [AgentRunRecord] {
        lock.lock()
        defer { lock.unlock() }
        var runs: [AgentRunRecord] = []
        let sql = """
            SELECT id, conversation_id, thread_id, parent_run_id, status,
                   checkpoint_message_count, model_round_count, tool_call_count,
                   started_at, updated_at, ended_at, error_message
            FROM agent_runs
            WHERE conversation_id = ?
            ORDER BY started_at ASC
            """
        do {
            try withStatement(sql) { statement in
                bind(conversationID.uuidString, at: 1, to: statement)
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard
                        let id = UUID(uuidString: text(statement, 0)),
                        let storedConversationID = UUID(uuidString: text(statement, 1)),
                        let status = AgentRunStatus(rawValue: text(statement, 4))
                    else { continue }
                    runs.append(
                        AgentRunRecord(
                            id: id,
                            conversationID: storedConversationID,
                            threadID: text(statement, 2),
                            parentRunID: optionalText(statement, 3).flatMap(UUID.init(uuidString:)),
                            status: status,
                            checkpointMessageCount: Int(sqlite3_column_int(statement, 5)),
                            modelRoundCount: Int(sqlite3_column_int(statement, 6)),
                            toolCallCount: Int(sqlite3_column_int(statement, 7)),
                            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                            endedAt: optionalDouble(statement, 10).map(Date.init(timeIntervalSince1970:)),
                            errorMessage: optionalText(statement, 11)
                        )
                    )
                }
            }
        } catch {
            return []
        }
        return runs
    }

    func latestRecoverableRun(conversationID: UUID) -> AgentRunRecord? {
        loadRuns(conversationID: conversationID).last(where: { $0.status.isRecoverable })
    }

    func markActiveRunsInterrupted() throws {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let active = [
            AgentRunStatus.preparing.rawValue,
            AgentRunStatus.retrieving.rawValue,
            AgentRunStatus.generating.rawValue,
            AgentRunStatus.executingTool.rawValue,
            AgentRunStatus.finalizing.rawValue
        ]
        let placeholders = active.map { _ in "?" }.joined(separator: ",")
        let sql = """
            UPDATE agent_runs
            SET status = ?, updated_at = ?, ended_at = ?,
                error_message = COALESCE(error_message, '应用退出前运行未完成')
            WHERE status IN (\(placeholders))
            """
        try withStatement(sql) { statement in
            bind(AgentRunStatus.interrupted.rawValue, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, now)
            sqlite3_bind_double(statement, 3, now)
            for (offset, value) in active.enumerated() {
                bind(value, at: Int32(offset + 4), to: statement)
            }
            try stepDone(statement)
        }
    }

    // MARK: - Run Steps

    func saveStep(_ step: AgentRunStep) {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
            INSERT INTO run_steps (
                id, run_id, sequence, kind, status, title, detail,
                tool_name, started_at, ended_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                sequence = excluded.sequence,
                status = excluded.status,
                title = excluded.title,
                detail = excluded.detail,
                tool_name = excluded.tool_name,
                ended_at = excluded.ended_at
            """
        do {
            try withStatement(sql) { statement in
                bind(step.id.uuidString, at: 1, to: statement)
                bind(step.runID.uuidString, at: 2, to: statement)
                sqlite3_bind_int(statement, 3, Int32(step.sequence))
                bind(step.kind.rawValue, at: 4, to: statement)
                bind(step.status.rawValue, at: 5, to: statement)
                bind(step.title, at: 6, to: statement)
                bind(step.detail, at: 7, to: statement)
                bind(step.toolName, at: 8, to: statement)
                sqlite3_bind_double(statement, 9, step.startedAt.timeIntervalSince1970)
                bind(step.endedAt?.timeIntervalSince1970, at: 10, to: statement)
                try stepDone(statement)
            }
        } catch {
            assertionFailure("保存运行步骤失败: \(error.localizedDescription)")
        }
    }

    func loadSteps(runID: UUID) -> [AgentRunStep] {
        lock.lock()
        defer { lock.unlock() }
        var steps: [AgentRunStep] = []
        let sql = """
            SELECT id, run_id, sequence, kind, status, title, detail,
                   tool_name, started_at, ended_at
            FROM run_steps
            WHERE run_id = ?
            ORDER BY sequence ASC
            """
        do {
            try withStatement(sql) { statement in
                bind(runID.uuidString, at: 1, to: statement)
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard
                        let id = UUID(uuidString: text(statement, 0)),
                        let storedRunID = UUID(uuidString: text(statement, 1)),
                        let kind = AgentRunStepKind(rawValue: text(statement, 3)),
                        let status = AgentRunStepStatus(rawValue: text(statement, 4))
                    else { continue }
                    steps.append(
                        AgentRunStep(
                            id: id,
                            runID: storedRunID,
                            sequence: Int(sqlite3_column_int(statement, 2)),
                            kind: kind,
                            status: status,
                            title: text(statement, 5),
                            detail: text(statement, 6),
                            toolName: optionalText(statement, 7),
                            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                            endedAt: optionalDouble(statement, 9).map(Date.init(timeIntervalSince1970:))
                        )
                    )
                }
            }
        } catch {
            return []
        }
        return steps
    }

    // MARK: - Edit Idempotency

    @discardableResult
    func recordAppliedEdit(
        editID: UUID,
        conversationID: UUID?,
        runID: UUID?,
        filePath: String?,
        resultFingerprint: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
            INSERT OR IGNORE INTO applied_edits (
                edit_id, conversation_id, run_id, file_path,
                result_fingerprint, applied_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """
        do {
            try withStatement(sql) { statement in
                bind(editID.uuidString, at: 1, to: statement)
                bind(conversationID?.uuidString, at: 2, to: statement)
                bind(runID?.uuidString, at: 3, to: statement)
                bind(filePath.map(Self.normalize), at: 4, to: statement)
                bind(resultFingerprint, at: 5, to: statement)
                sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
                try stepDone(statement)
            }
            return sqlite3_changes(database) == 1
        } catch {
            return false
        }
    }

    func hasAppliedEdit(_ editID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var found = false
        try? withStatement("SELECT 1 FROM applied_edits WHERE edit_id = ? LIMIT 1") { statement in
            bind(editID.uuidString, at: 1, to: statement)
            found = sqlite3_step(statement) == SQLITE_ROW
        }
        return found
    }

    // MARK: - SQLite

    private func configureDatabase() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=3000")
        try execute("PRAGMA synchronous=NORMAL")
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                primary_file_path TEXT,
                project_root_path TEXT,
                messages_json BLOB NOT NULL,
                context_json BLOB NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                is_archived INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_conversations_file ON conversations(primary_file_path, updated_at DESC)")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS agent_runs (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                thread_id TEXT NOT NULL,
                parent_run_id TEXT,
                status TEXT NOT NULL,
                checkpoint_message_count INTEGER NOT NULL,
                model_round_count INTEGER NOT NULL DEFAULT 0,
                tool_call_count INTEGER NOT NULL DEFAULT 0,
                started_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                ended_at REAL,
                error_message TEXT
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_runs_conversation ON agent_runs(conversation_id, started_at)")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS run_steps (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL,
                kind TEXT NOT NULL,
                status TEXT NOT NULL,
                title TEXT NOT NULL,
                detail TEXT NOT NULL,
                tool_name TEXT,
                started_at REAL NOT NULL,
                ended_at REAL
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_steps_run ON run_steps(run_id, sequence)")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS applied_edits (
                edit_id TEXT PRIMARY KEY,
                conversation_id TEXT,
                run_id TEXT,
                file_path TEXT,
                result_fingerprint TEXT NOT NULL,
                applied_at REAL NOT NULL
            )
            """
        )
        try execute("PRAGMA user_version=1")
    }

    private func migrateLegacyConversationsIfNeeded() throws {
        guard let legacyDirectoryURL else { return }
        let alreadyMigrated = try scalarInt("SELECT COUNT(*) FROM conversations") > 0
        guard !alreadyMigrated else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: legacyDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let conversation = try? decoder.decode(Conversation.self, from: data)
            else { continue }
            save(conversation)
        }
    }

    private func queryConversations(sql: String, bindValues: [String] = []) -> [Conversation] {
        lock.lock()
        defer { lock.unlock() }
        var conversations: [Conversation] = []
        do {
            try withStatement(sql) { statement in
                for (index, value) in bindValues.enumerated() {
                    bind(value, at: Int32(index + 1), to: statement)
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard
                        let id = UUID(uuidString: text(statement, 0)),
                        let messagesData = data(statement, 5),
                        let contextData = data(statement, 6),
                        let messages = try? decoder.decode([ChatMessage].self, from: messagesData),
                        let context = try? decoder.decode(ConversationContext.self, from: contextData)
                    else { continue }
                    conversations.append(
                        Conversation(
                            id: id,
                            title: text(statement, 2),
                            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                            messages: messages,
                            threadID: text(statement, 1),
                            context: context,
                            isPinned: sqlite3_column_int(statement, 7) == 1,
                            isArchived: sqlite3_column_int(statement, 8) == 1
                        )
                    )
                }
            }
        } catch {
            return []
        }
        return conversations
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw currentError()
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var result = 0
        try withStatement(sql) { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                result = Int(sqlite3_column_int64(statement, 0))
            }
        }
        return result
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let database else { throw StoreError.databaseUnavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw currentError()
        }
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
        }
    }

    private func bind(_ value: Double?, at index: Int32, to statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(statement, index)
    }

    private func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func data(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard
            let bytes = sqlite3_column_blob(statement, index),
            sqlite3_column_type(statement, index) != SQLITE_NULL
        else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func currentError() -> StoreError {
        guard let database else { return .databaseUnavailable }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StoreError: LocalizedError {
    case openFailed(String)
    case databaseUnavailable
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "无法打开数据库：\(message)"
        case .databaseUnavailable: return "数据库不可用"
        case .sqlite(let message): return "数据库错误：\(message)"
        }
    }
}
