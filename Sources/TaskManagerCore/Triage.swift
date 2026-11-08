import Foundation

public enum SourceDisposition: String, Codable, Sendable {
    case pending, triaging, routed, created, ignored, waitingForUser, failed
}

public struct IncomingSource: Codable, Sendable, Identifiable {
    public let id: Int64
    public let integration: String
    public let sourceID: String
    public let revision: String
    public let associationKey: String
    public let body: String
    public let url: String
    public let repository: String
    public let workerKind: WorkerKind
    public let disposition: SourceDisposition
    public let taskID: String?
    public let reason: String?
    public let question: String?
    public let clarification: String?
    public let lastError: String?
    public let attempts: Int
    public let messageID: String?
    public let messageDelivered: Bool?
}

public enum TriageAction: String, Codable, Sendable { case route, create, ignore, clarify }

public struct TriageDecision: Codable, Sendable {
    public let action: TriageAction
    public let taskID: String?
    public let goal: String?
    public let reason: String
    public let question: String?

    public init(action: TriageAction, taskID: String? = nil, goal: String? = nil, reason: String, question: String? = nil) {
        self.action = action; self.taskID = taskID; self.goal = goal; self.reason = reason; self.question = question
    }

    public func validate() throws {
        try requireText(reason, name: "Decision reason")
        guard reason.count <= 4096 else { throw ManagerError.invalid("Decision reason is too long") }
        switch action {
        case .route:
            guard let taskID, goal == nil, question == nil else { throw ManagerError.invalid("Route requires only a task ID") }
            try requireText(taskID, name: "Target task ID")
        case .create:
            guard let goal, taskID == nil, question == nil, goal.count <= 8192 else { throw ManagerError.invalid("Create requires only a bounded goal") }
            try requireText(goal, name: "New task goal")
        case .ignore:
            guard taskID == nil, goal == nil, question == nil else { throw ManagerError.invalid("Ignore cannot target or create work") }
        case .clarify:
            guard let question, taskID == nil, goal == nil, question.count <= 4096 else { throw ManagerError.invalid("Clarify requires only a question") }
            try requireText(question, name: "Clarification question")
        }
    }
}

public struct TriageCandidate: Codable, Sendable {
    public let id: String
    public let goal: String
    public let status: TaskStatus
    public let repository: String
    public let recentContext: [String]

    public init(id: String, goal: String, status: TaskStatus, repository: String, recentContext: [String]) {
        self.id = id; self.goal = goal; self.status = status; self.repository = repository; self.recentContext = recentContext
    }
}
