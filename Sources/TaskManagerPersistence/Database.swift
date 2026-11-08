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

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
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
            guard ["0", "1", "2", "3", "4"].contains(version) else {
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
            if version != "4" {
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
        }
    }
}
