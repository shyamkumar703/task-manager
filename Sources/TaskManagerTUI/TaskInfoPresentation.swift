import Foundation
import TaskManagerCore

struct TaskInfoSection {
    let title: String
    let text: String
    var style: Int32 = 0
}

enum TaskInfoPresentation {
    static func sections(_ info: TaskInfo) -> [TaskInfoSection] {
        let task = info.task
        let creation = info.journal.first { $0.kind == "triage.created" || $0.kind == "source.reinvestigated" }
        let originatingSource = creation.flatMap { entry in
            info.sources.first { entry.detail.hasPrefix("\($0.id): ") || entry.detail.hasPrefix("Source \($0.id);") }
        }
        let origin: String
        if let source = originatingSource, let creation {
            let mechanism = creation.kind == "source.reinvestigated" ? "Independent investigation requested by user" : "Created from"
            origin = "\(mechanism) \(source.integration.capitalized) message #\(source.id)\n\(source.url)\n\(creation.detail)"
        } else if let creation { origin = "Created by source triage\n\(creation.detail)" }
        else if let key = task.sourceKey { origin = "Created with source association: \(key)\nThe creation mechanism was not recorded." }
        else { origin = "Created locally (TUI or CLI); no source creation decision was recorded." }
        var result = [TaskInfoSection(title: "STARTED", text: "\(task.createdAt)\n\(origin)"), TaskInfoSection(title: "GOAL", text: task.goal)]
        var runtime = "ID: \(task.id)\nStatus: \(task.status == .completed ? "Ready for follow-up (latest scope finished)" : task.status.rawValue)\nUpdated: \(task.updatedAt)"
        if let session = info.session {
            runtime += "\n" + "Project: \(session.repository)\nWorker: \(session.kind.rawValue) / \(session.purpose.rawValue)"
            if let path = session.workspace { runtime += "\nWorktree: \(path)" }
            if let thread = session.threadID { runtime += "\nCodex thread: \(thread)" }
            if let ref = session.baseRef { runtime += "\nSnapshot: \(ref) @ \(session.baseSHA ?? "unknown")" }
        }
        result.append(.init(title: "TASK DETAILS", text: runtime, style: 3))
        result.append(.init(title: "CONNECTION MESSAGES [\(info.sources.count)]", text: "Accepted means delivered to a child turn; it does not prove the agent followed the message. Held messages have not been forwarded.", style: 3))
        for source in info.sources {
            let sameTask = source.taskID == task.id
            let delivery = !sameTask ? "Previously linked; now associated with another child" : source.messageDelivered.map { $0 ? "Accepted by child" : "Queued; not yet accepted" } ?? "Not forwarded (\(source.disposition.rawValue))"
            var body = "\(delivery)\n\(source.url)\nSource ID: \(source.sourceID)\nAssociation: \(source.associationKey)\n\n\(source.body)"
            if let reason = source.reason { body += "\n\nLatest routing decision: \(reason)" }
            if let context = source.githubContext {
                body += "\n\nPR context: \(context.repository) #\(context.pullRequest)\nHead branch: \(context.headBranch) @ \(context.headSHA)\nCheckout: \(context.checkout ?? "Not locally checked out")\nOwning task: \(context.owningTaskID ?? "Unassigned")"
            }
            if let discovery = source.githubContext?.discoveryReason { body += "\n\nPR discovery: " + discovery }
            if let evidence = source.githubContext?.liveEvidence { body += "\n\nLive GitHub evidence at \(source.githubContext?.checkedAt ?? "unknown time"):\n" + evidence }
            if let context = source.slackContext {
                body += "\n\nContext: \(context.workspaceName) / #\(context.channelName)\nTopic: \(context.topic ?? "—")\nPurpose: \(context.purpose ?? "—")"
                for (label, messages) in [("Preceding channel messages", context.precedingMessages), ("Thread messages", context.threadMessages)] where !messages.isEmpty {
                    body += "\n\n" + label
                    for message in messages { body += "\n[\(message.timestamp) · \(message.author)] \(message.text)" }
                }
                for evidence in context.projectHistory {
                    body += "\n\nPrior project context: \(evidence.repository)\n\(evidence.message)\n\(evidence.reason)"
                    if let answer = evidence.userClarification { body += "\nUser clarification: " + answer }
                }
            }
            if let question = source.question { body += "\n\nClarification requested: \(question)" }
            if let answer = source.clarification { body += "\nUser clarification: \(answer)" }
            result.append(.init(title: "\(source.integration.uppercased()) #\(source.id) · revision \(source.revision)", text: body, style: source.messageDelivered == false ? 4 : 0))
        }
        let sourceMessages = Set(info.sources.compactMap(\.messageID))
        for message in info.messages where !sourceMessages.contains(message.id) {
            result.append(.init(title: "TASK MESSAGE · \(message.delivered ? "ACCEPTED" : "QUEUED")", text: message.body, style: message.delivered ? 0 : 4))
        }
        for question in info.questions {
            result.append(.init(title: question.answer == nil ? "QUESTION · AWAITING ANSWER" : "QUESTION · ANSWERED", text: question.prompt + "\n\nAnswer: " + (question.answer ?? "Pending"), style: question.answer == nil ? 4 : 0))
        }
        result.append(.init(title: "DECISION / TRANSACTION HISTORY [\(info.journal.count)]", text: "Recorded events in chronological order. This includes routing reasons, questions, state changes, and delivery acknowledgements; private model reasoning is not recorded.", style: 3))
        for entry in info.journal {
            result.append(.init(title: "\(entry.createdAt) · \(entry.kind)", text: entry.detail, style: entry.kind.contains("error") || entry.kind.contains("failed") ? 6 : 0))
        }
        return result
    }
}
