import Foundation

public struct SlackMessage: Codable, Sendable, Equatable {
    public let timestamp: String
    public let threadTimestamp: String
    public let author: String
    public let text: String
    public init(timestamp: String, threadTimestamp: String, author: String, text: String) {
        self.timestamp = timestamp; self.threadTimestamp = threadTimestamp; self.author = author; self.text = text
    }
}
public struct SlackProjectEvidence: Codable, Sendable {
    public let repository: String
    public let sourceID: String
    public let message: String
    public let reason: String
    public let userClarification: String?
    public init(repository: String, sourceID: String, message: String, reason: String, userClarification: String?) {
        self.repository = repository; self.sourceID = sourceID; self.message = message; self.reason = reason; self.userClarification = userClarification
    }
}
public struct SlackRoutingContext: Codable, Sendable {
    public let workspaceName: String
    public let channelID: String
    public let channelName: String
    public let topic: String?
    public let purpose: String?
    public let precedingMessages: [SlackMessage]
    public let threadMessages: [SlackMessage]
    public let projectHistory: [SlackProjectEvidence]
    public init(workspaceName: String, channelID: String, channelName: String, topic: String?, purpose: String?, precedingMessages: [SlackMessage], threadMessages: [SlackMessage], projectHistory: [SlackProjectEvidence]) {
        self.workspaceName = workspaceName; self.channelID = channelID; self.channelName = channelName; self.topic = topic; self.purpose = purpose; self.precedingMessages = precedingMessages; self.threadMessages = threadMessages; self.projectHistory = projectHistory
    }
}
