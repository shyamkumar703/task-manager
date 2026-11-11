import Foundation

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case queued, running, waitingForUser, paused, completed, failed, cancelled

    public func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.queued, .running), (.queued, .paused), (.queued, .cancelled),
             (.running, .queued), (.running, .waitingForUser), (.running, .paused),
             (.running, .completed), (.running, .failed), (.running, .cancelled),
             (.waitingForUser, .queued), (.waitingForUser, .paused), (.waitingForUser, .cancelled),
             (.paused, .queued), (.paused, .waitingForUser), (.paused, .cancelled),
             (.completed, .queued), (.failed, .queued), (.failed, .cancelled): true
        default: false
        }
    }
}

public struct ManagedTask: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let goal: String
    public let status: TaskStatus
    public let sourceKey: String?
    public let createdAt: String
    public let updatedAt: String
    public let archivedAt: String?
}

public struct TaskMessage: Codable, Sendable, Identifiable {
    public let id: String
    public let taskID: String
    public let body: String
    public let delivered: Bool
}

public struct Question: Codable, Sendable, Identifiable {
    public let id: String
    public let taskID: String
    public let prompt: String
    public let answer: String?
}

public struct JournalEntry: Codable, Sendable, Identifiable {
    public let id: Int64
    public let taskID: String?
    public let kind: String
    public let detail: String
    public let createdAt: String
}

public struct SourceEvent: Codable, Sendable, Equatable {
    public let integration: String
    public let sourceID: String
    public let revision: String
    public let associationKey: String
    public let body: String
    public let url: String
    public let slackMessage: SlackMessage?

    public init(integration: String, sourceID: String, revision: String, associationKey: String, body: String, url: String, slackMessage: SlackMessage? = nil) {
        self.integration = integration
        self.sourceID = sourceID
        self.revision = revision
        self.associationKey = associationKey
        self.body = body
        self.url = url
        self.slackMessage = slackMessage
    }
}

public enum ApprovalStatus: String, Codable, Sendable {
    case pending, approved, rejected
}

/// An immutable payload. Changing a proposed action requires creating a new proposal.
public struct ActionProposal: Codable, Sendable, Identifiable {
    public let id: String
    public let taskID: String
    public let kind: String
    public let target: String
    public let body: String
    public let expectedHead: String
    public let status: ApprovalStatus
}

public enum ManagerError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    case notFound(String)
    case conflict(String)
    case storage(String)

    public var description: String {
        switch self {
        case .invalid(let text), .notFound(let text), .conflict(let text), .storage(let text): text
        }
    }
}

public func requireText(_ text: String, name: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !text.contains("\0") else { throw ManagerError.invalid("\(name) must be nonempty and contain no NUL characters") }
}

public enum WorkerKind: String, Codable, Sendable { case mock, codex }

public struct AgentSessionRecord: Codable, Sendable {
    public let taskID: String
    public let repository: String
    public let workspace: String?
    public let kind: WorkerKind
    public let threadID: String?
    public let turnID: String?
    public let purpose: WorkerPurpose
    public let baseRef: String?
    public let baseSHA: String?
    public let workerActive: Bool
    public let manualActive: Bool
}

public struct AgentOutput: Codable, Sendable, Identifiable {
    public let id: Int64
    public let taskID: String
    public let itemID: String
    public let kind: String
    public let text: String
}

public enum WorkerPurpose: String, Codable, Sendable { case implementation, exploration }

public struct UserAction: Codable, Sendable, Identifiable {
    public let id: String
    public let taskID: String
    public let sourceEventID: Int64
    public let target: String
    public let body: String
    public let context: String
    public let status: String
}

public struct SourceReply: Codable, Sendable {
    public let sourceEventID: Int64
    public let text: String
    public init(sourceEventID: Int64, text: String) { self.sourceEventID = sourceEventID; self.text = text }
}

public struct SourceReplyRequest: Codable, Sendable {
    public let sourceEventID: Int64
    public let url: String
    public let body: String
    public init(sourceEventID: Int64, url: String, body: String) { self.sourceEventID = sourceEventID; self.url = url; self.body = body }
}
