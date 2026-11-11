import CSQLite
import Foundation
import TaskManagerCore

/// Confined to Store's actor. Never passed across actor boundaries.
final class Database {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw ManagerError.storage(reason)
        }
        sqlite3_busy_timeout(handle, 5000)
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try migrate()
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    var lastID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String, _ bindings: [String?] = []) throws {
        _ = try query(sql, bindings)
    }

    func query(_ sql: String, _ bindings: [String?] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == bindings.count else {
            throw ManagerError.storage("SQL binding count mismatch")
        }
        for (index, value) in bindings.enumerated() {
            let code: Int32
            if let value {
                code = sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            } else {
                code = sqlite3_bind_null(statement, Int32(index + 1))
            }
            guard code == SQLITE_OK else { throw failure() }
        }
        var rows: [[String: String]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row: [String: String] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let key = String(cString: sqlite3_column_name(statement, index))
                    if let value = sqlite3_column_text(statement, index) {
                        row[key] = String(cString: value)
                    }
                }
                rows.append(row)
            case SQLITE_DONE: return rows
            default: throw failure()
            }
        }
    }

    func transaction<T>(readOnly: Bool = false, _ body: () throws -> T) throws -> T {
        try execute(readOnly ? "BEGIN" : "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func failure() -> ManagerError {
        .storage(String(cString: sqlite3_errmsg(handle)))
    }

    private func migrate() throws {
        try transaction {
            let version = try query("PRAGMA user_version").first?["user_version"] ?? "0"
            guard ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17"].contains(version) else {
                throw ManagerError.storage("Database schema \(version) is newer than this application")
            }
            if version == "0" {
            let statements = [
                """
                CREATE TABLE tasks (
                    id TEXT PRIMARY KEY, goal TEXT NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('queued','running','waitingForUser','paused','completed','failed','cancelled')),
                    source_key TEXT UNIQUE, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE messages (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL,
                    task_id TEXT NOT NULL REFERENCES tasks(id), body TEXT NOT NULL,
                    delivered INTEGER NOT NULL DEFAULT 0 CHECK(delivered IN (0,1))
                )
                """,
                """
                CREATE TABLE questions (
                    id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id),
                    prompt TEXT NOT NULL, answer TEXT
                )
                """,
                "CREATE UNIQUE INDEX one_pending_question ON questions(task_id) WHERE answer IS NULL",
                """
                CREATE TABLE events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, integration TEXT NOT NULL,
                    source_id TEXT NOT NULL, revision TEXT NOT NULL, association_key TEXT NOT NULL,
                    body TEXT NOT NULL, url TEXT NOT NULL,
                    task_id TEXT REFERENCES tasks(id), disposition TEXT NOT NULL DEFAULT 'pending',
                    UNIQUE(integration, source_id, revision)
                )
                """,
                """
                CREATE TABLE journal (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT REFERENCES tasks(id),
                    kind TEXT NOT NULL, detail TEXT NOT NULL, created_at TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE proposals (
                    id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id),
                    kind TEXT NOT NULL, target TEXT NOT NULL, body TEXT NOT NULL, expected_head TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','rejected'))
                )
                """,
                "PRAGMA user_version = 1",
            ]
            for statement in statements { try execute(statement) }
            }
            if ["0", "1"].contains(version) {
                try execute("""
                    CREATE TABLE agent_sessions (
                        task_id TEXT PRIMARY KEY REFERENCES tasks(id), repository TEXT NOT NULL,
                        workspace TEXT, kind TEXT NOT NULL CHECK(kind IN ('mock','codex')),
                        thread_id TEXT, turn_id TEXT
                    )
                    """)
                try execute("""
                    CREATE TABLE agent_output (
                        sequence INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL REFERENCES tasks(id),
                        item_id TEXT NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL,
                        UNIQUE(task_id, item_id)
                    )
                    """)
                try execute("PRAGMA user_version = 2")
            }
            if ["0", "1", "2"].contains(version) {
                try execute("ALTER TABLE tasks ADD COLUMN archived_at TEXT")
                try execute("ALTER TABLE agent_sessions ADD COLUMN worker_active INTEGER NOT NULL DEFAULT 0 CHECK(worker_active IN (0,1))")
                try execute("ALTER TABLE agent_sessions ADD COLUMN manual_active INTEGER NOT NULL DEFAULT 0 CHECK(manual_active IN (0,1))")
                try execute("PRAGMA user_version = 3")
            }
            if ["0", "1", "2", "3"].contains(version) {
                try execute("""
                    CREATE TABLE event_context (
                        event_id INTEGER PRIMARY KEY REFERENCES events(id), repository TEXT NOT NULL,
                        worker_kind TEXT NOT NULL CHECK(worker_kind IN ('mock','codex')),
                        reason TEXT, question TEXT, clarification TEXT, last_error TEXT,
                        attempts INTEGER NOT NULL DEFAULT 0, retry_after REAL NOT NULL DEFAULT 0,
                        message_id TEXT REFERENCES messages(id)
                    )
                    """)
                try execute("""
                    CREATE TABLE source_links (
                        repository TEXT NOT NULL, association_key TEXT NOT NULL,
                        task_id TEXT NOT NULL REFERENCES tasks(id),
                        PRIMARY KEY(repository, association_key)
                    )
                    """)
                try execute("PRAGMA user_version = 4")
            }
            if ["0", "1", "2", "3", "4"].contains(version) {
                try execute("CREATE TABLE IF NOT EXISTS polling_cursors (source_key TEXT PRIMARY KEY, repository TEXT NOT NULL, worker_kind TEXT NOT NULL, generation INTEGER NOT NULL, completed_at TEXT NOT NULL)")
                try execute("PRAGMA user_version = 5")
            }
            if ["0", "1", "2", "3", "4", "5"].contains(version) {
                try execute("CREATE TABLE IF NOT EXISTS github_sources (id TEXT PRIMARY KEY, repository TEXT NOT NULL UNIQUE, local_repository TEXT NOT NULL, author TEXT NOT NULL, interval_seconds INTEGER NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, last_success REAL, next_poll REAL NOT NULL DEFAULT 0, last_error TEXT, failures INTEGER NOT NULL DEFAULT 0)")
                try execute("PRAGMA user_version = 6")
            }
            if ["0", "1", "2", "3", "4", "5", "6"].contains(version) {
                try execute("CREATE TABLE IF NOT EXISTS slack_sources (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, workspace_name TEXT NOT NULL, user_id TEXT NOT NULL, channel_id TEXT NOT NULL, channel_name TEXT NOT NULL, repository TEXT NOT NULL, interval_seconds INTEGER NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, last_success REAL, next_poll REAL NOT NULL DEFAULT 0, last_error TEXT, failures INTEGER NOT NULL DEFAULT 0)")
                try execute("PRAGMA user_version = 7")
            }
            if ["0", "1", "2", "3", "4", "5", "6", "7"].contains(version) {
                try execute("CREATE TABLE IF NOT EXISTS projects (repository TEXT PRIMARY KEY)")
                try execute("CREATE TABLE IF NOT EXISTS slack_workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, user_id TEXT NOT NULL, next_discovery REAL NOT NULL DEFAULT 0, last_success REAL, last_error TEXT, failures INTEGER NOT NULL DEFAULT 0)")
                try execute("PRAGMA user_version = 8")
            }
            if ["0", "1", "2", "3", "4", "5", "6", "7", "8"].contains(version) {
                let columns = try query("PRAGMA table_info(agent_sessions)").compactMap { $0["name"] }
                if !columns.contains("purpose") { try execute("ALTER TABLE agent_sessions ADD COLUMN purpose TEXT NOT NULL DEFAULT 'implementation'") }
                if !columns.contains("base_ref") { try execute("ALTER TABLE agent_sessions ADD COLUMN base_ref TEXT") }
                if !columns.contains("base_sha") { try execute("ALTER TABLE agent_sessions ADD COLUMN base_sha TEXT") }
                try execute("CREATE TABLE IF NOT EXISTS user_actions (id TEXT PRIMARY KEY, task_id TEXT NOT NULL UNIQUE REFERENCES tasks(id), source_event_id INTEGER NOT NULL REFERENCES events(id), target TEXT NOT NULL, body TEXT NOT NULL, context TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','done','dismissed')))")
                try execute("PRAGMA user_version = 9")
            }
            if Int(version)! < 10 {
                let sourceColumns = try query("PRAGMA table_info(slack_sources)").compactMap { $0["name"] }
                if !sourceColumns.contains("channel_topic") { try execute("ALTER TABLE slack_sources ADD COLUMN channel_topic TEXT") }
                if !sourceColumns.contains("channel_purpose") { try execute("ALTER TABLE slack_sources ADD COLUMN channel_purpose TEXT") }
                if !(try query("PRAGMA table_info(event_context)").compactMap { $0["name"] }).contains("routing_context") {
                    try execute("ALTER TABLE event_context ADD COLUMN routing_context TEXT")
                }
                try execute("CREATE TABLE IF NOT EXISTS slack_messages (source_key TEXT NOT NULL REFERENCES slack_sources(id), timestamp TEXT NOT NULL, thread_timestamp TEXT NOT NULL, author TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(source_key, timestamp))")
                try execute("UPDATE slack_workspaces SET next_discovery = 0")
                try execute("PRAGMA user_version = 10")
            }
            if Int(version)! < 11 {
                let columns = try query("PRAGMA table_info(event_context)").compactMap { $0["name"] }
                if !columns.contains("github_context") { try execute("ALTER TABLE event_context ADD COLUMN github_context TEXT") }
                try execute("PRAGMA user_version = 11")
            }
            if Int(version)! < 12 {
                try execute("""
                    CREATE TABLE IF NOT EXISTS usage_threads (
                        thread_id TEXT PRIMARY KEY, task_id TEXT REFERENCES tasks(id),
                        source_event_id INTEGER REFERENCES events(id), role TEXT NOT NULL,
                        model TEXT NOT NULL, provider TEXT NOT NULL, effort TEXT, service_tier TEXT,
                        counters TEXT, resumed INTEGER NOT NULL DEFAULT 0
                    )
                    """)
                try execute("""
                    CREATE TABLE IF NOT EXISTS usage_turns (
                        thread_id TEXT NOT NULL REFERENCES usage_threads(thread_id), turn_id TEXT NOT NULL,
                        model TEXT NOT NULL, provider TEXT NOT NULL, effort TEXT,
                        input_tokens INTEGER NOT NULL, cached_tokens INTEGER NOT NULL, cache_write_tokens INTEGER NOT NULL,
                        output_tokens INTEGER NOT NULL, reasoning_tokens INTEGER NOT NULL, total_tokens INTEGER NOT NULL,
                        price TEXT, unpriceable INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL,
                        PRIMARY KEY(thread_id, turn_id, model, provider)
                    )
                    """)
                try execute("CREATE TABLE IF NOT EXISTS usage_prices (model TEXT NOT NULL, provider TEXT NOT NULL, price TEXT NOT NULL, PRIMARY KEY(model, provider))")
                try execute("PRAGMA user_version = 12")
            }
            if Int(version)! < 13 {
                if !(try query("PRAGMA table_info(event_context)").compactMap { $0["name"] }).contains("reply_requested") {
                    try execute("ALTER TABLE event_context ADD COLUMN reply_requested INTEGER NOT NULL DEFAULT 0 CHECK(reply_requested IN (0,1))")
                }
                // A continuing implementation task can answer multiple independent sources.
                try execute("""
                    CREATE TABLE user_actions_v13 (
                        id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id),
                        source_event_id INTEGER NOT NULL REFERENCES events(id), target TEXT NOT NULL,
                        body TEXT NOT NULL, context TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','done','dismissed')),
                        UNIQUE(task_id, source_event_id)
                    )
                    """)
                try execute("INSERT INTO user_actions_v13 SELECT * FROM user_actions")
                try execute("DROP TABLE user_actions")
                try execute("ALTER TABLE user_actions_v13 RENAME TO user_actions")
                try execute("PRAGMA user_version = 13")
            }
            if Int(version)! < 14 {
                try execute("CREATE TABLE IF NOT EXISTS slack_user_names (workspace_id TEXT NOT NULL, user_id TEXT NOT NULL, name TEXT, next_lookup REAL NOT NULL DEFAULT 0, PRIMARY KEY(workspace_id, user_id))")
                try execute("PRAGMA user_version = 14")
            }
            if Int(version)! < 15 {
                try execute("CREATE TABLE IF NOT EXISTS activity_hidden_events (event_id INTEGER PRIMARY KEY REFERENCES events(id))")
                try execute("PRAGMA user_version = 15")
            }
            if Int(version)! < 16 {
                if !(try query("PRAGMA table_info(slack_workspaces)").compactMap { $0["name"] }).contains("poll_interval_seconds") {
                    try execute("ALTER TABLE slack_workspaces ADD COLUMN poll_interval_seconds INTEGER NOT NULL DEFAULT 60 CHECK(poll_interval_seconds BETWEEN 10 AND 86400)")
                }
                try execute("PRAGMA user_version = 16")
            }
            if Int(version)! < 17 {
                // SQLite cannot alter a CHECK constraint in place. Preserve all workspace state.
                try execute("""
                    CREATE TABLE slack_workspaces_v17 (
                        id TEXT PRIMARY KEY, name TEXT NOT NULL, user_id TEXT NOT NULL,
                        next_discovery REAL NOT NULL DEFAULT 0, last_success REAL, last_error TEXT,
                        failures INTEGER NOT NULL DEFAULT 0,
                        poll_interval_seconds INTEGER NOT NULL DEFAULT 60 CHECK(poll_interval_seconds BETWEEN 1 AND 86400)
                    )
                    """)
                try execute("INSERT INTO slack_workspaces_v17 SELECT id, name, user_id, next_discovery, last_success, last_error, failures, poll_interval_seconds FROM slack_workspaces")
                try execute("DROP TABLE slack_workspaces")
                try execute("ALTER TABLE slack_workspaces_v17 RENAME TO slack_workspaces")
                try execute("PRAGMA user_version = 17")
            }
        }
    }
}
