import Foundation
import TaskManagerCore

/// All durable work awaiting the user, independent of the task list or recent-activity limit.
enum AttentionItem: Identifiable, Sendable {
    case sourceQuestion(IncomingSource)
    case workerQuestion(Question, ManagedTask)
    case reply(UserAction)
    case approval(ActionProposal)
    case failedTask(ManagedTask)
    case failedSource(IncomingSource)
    case slackProblem(SlackSource)
    case slackDiscoveryProblem(SlackWorkspace)
    case githubProblem(GitHubSource)

    var id: String {
        switch self {
        case .sourceQuestion(let s), .failedSource(let s): "source:\(s.id)"
        case .workerQuestion(let q, _): "question:\(q.id)"
        case .reply(let a): "reply:\(a.id)"
        case .approval(let p): "approval:\(p.id)"
        case .failedTask(let t): "task:\(t.id)"
        case .slackProblem(let s): "slack:\(s.id)"
        case .slackDiscoveryProblem(let s): "discovery:\(s.id)"
        case .githubProblem(let s): "github:\(s.id)"
        }
    }
    var label: String {
        switch self {
        case .sourceQuestion, .workerQuestion: "ANSWER"
        case .reply: "REPLY READY"
        case .approval: "APPROVAL"
        case .failedTask, .failedSource: "FAILED"
        default: "CHECK CONNECTION"
        }
    }
    var title: String {
        switch self {
        case .sourceQuestion(let s): s.question ?? "Clarify this message"
        case .workerQuestion(let q, _): q.prompt
        case .reply(let a): a.body
        case .approval(let p): "Review \(p.kind)"
        case .failedTask(let t): t.goal
        case .failedSource(let s): s.lastError ?? "Source review failed"
        case .slackProblem(let s): "Slack / \(s.channelName)"
        case .slackDiscoveryProblem(let s): "Slack / \(s.name)"
        case .githubProblem(let s): "GitHub / \(s.repository)"
        }
    }
    var subtitle: String {
        switch self {
        case .sourceQuestion(let s), .failedSource(let s): sourceLabel(s)
        case .workerQuestion(_, let t): t.goal
        case .reply(let a): a.target.hasPrefix("slack:") ? "Slack" : "Source response"
        case .approval(let p): p.target
        case .failedTask: "Child stopped; inspect before retrying"
        case .slackProblem(let s): s.lastError ?? "Polling failed"
        case .slackDiscoveryProblem(let s): s.lastError ?? "Discovery failed"
        case .githubProblem(let s): s.lastError ?? "Polling failed"
        }
    }
    var taskID: String? {
        switch self {
        case .sourceQuestion(let s), .failedSource(let s): s.taskID
        case .workerQuestion(_, let t), .failedTask(let t): t.id
        case .reply(let a): a.taskID
        case .approval(let p): p.taskID
        default: nil
        }
    }
    var isFailure: Bool {
        switch self {
        case .failedTask, .failedSource, .slackProblem, .slackDiscoveryProblem, .githubProblem: true
        default: false
        }
    }
    private func sourceLabel(_ source: IncomingSource) -> String {
        if let c = source.slackContext { return "Slack #\(c.channelName)" }
        return "\(source.integration.capitalized) message #\(source.id)"
    }
}

enum DashboardModel {
    static func attention(tasks: [ManagedTask], questions: [Question], sources: [IncomingSource], actions: [UserAction], proposals: [ActionProposal], slack: [SlackSource], workspaces: [SlackWorkspace], github: [GitHubSource]) -> [AttentionItem] {
        var items = sources.filter { $0.disposition == .waitingForUser }.sorted { $0.id < $1.id }.map(AttentionItem.sourceQuestion)
        let live = Dictionary(uniqueKeysWithValues: tasks.filter { $0.archivedAt == nil && ![TaskStatus.cancelled, .completed, .failed].contains($0.status) }.map { ($0.id, $0) })
        items += questions.compactMap { q in q.answer == nil ? live[q.taskID].map { AttentionItem.workerQuestion(q, $0) } : nil }
        let approvable = Set(tasks.filter { $0.archivedAt == nil && $0.status != .cancelled }.map(\.id))
        items += proposals.filter { $0.status == .pending && approvable.contains($0.taskID) }.map(AttentionItem.approval)
        items += actions.filter { $0.status == "open" }.map(AttentionItem.reply)
        items += tasks.filter { $0.status == .failed && $0.archivedAt == nil }.map(AttentionItem.failedTask)
        items += sources.filter { $0.disposition == .failed }.map(AttentionItem.failedSource)
        items += slack.filter { $0.enabled && actionable($0.lastError, failures: $0.failures) }.map(AttentionItem.slackProblem)
        items += workspaces.filter { actionable($0.lastError, failures: $0.failures) }.map(AttentionItem.slackDiscoveryProblem)
        items += github.filter { $0.enabled && actionable($0.lastError, failures: $0.failures) }.map(AttentionItem.githubProblem)
        return items
    }
    static func work(_ tasks: [ManagedTask]) -> [ManagedTask] {
        let rank: [TaskStatus: Int] = [.running: 0, .queued: 1, .waitingForUser: 2, .paused: 3, .failed: 4, .completed: 5, .cancelled: 6]
        return tasks.sorted { (rank[$0.status]!, $0.createdAt, $0.id) < (rank[$1.status]!, $1.createdAt, $1.id) }
    }
    private static func actionable(_ error: String?, failures: Int) -> Bool {
        guard let error else { return false }
        return failures >= 3 || ["scope", "auth", "keychain", "credential", "token"].contains { error.lowercased().contains($0) }
    }
    static func preservedSelection(_ selected: String?, old: [String], new: [String]) -> String? {
        if let selected, new.contains(selected) { return selected }
        guard !new.isEmpty else { return nil }
        let index = selected.flatMap { old.firstIndex(of: $0) } ?? 0
        return new[min(index, new.count - 1)]
    }
}
