/// A consistent, durable inspection of a task, independent of the recent Activity window.
public struct TaskInfo: Sendable {
    public let task: ManagedTask
    public let session: AgentSessionRecord?
    public let messages: [TaskMessage]
    public let sources: [IncomingSource]
    public let journal: [JournalEntry]
    public let questions: [Question]

    public init(task: ManagedTask, session: AgentSessionRecord?, messages: [TaskMessage], sources: [IncomingSource], journal: [JournalEntry], questions: [Question] = []) {
        self.task = task; self.session = session; self.messages = messages; self.sources = sources; self.journal = journal; self.questions = questions
    }
}
