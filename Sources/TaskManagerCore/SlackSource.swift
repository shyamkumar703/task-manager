import Foundation

public struct SlackConversation: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isDM: Bool
    public let topic: String?
    public let purpose: String?
    public init(id: String, name: String, isDM: Bool, topic: String? = nil, purpose: String? = nil) {
        self.id = id; self.name = name; self.isDM = isDM; self.topic = topic; self.purpose = purpose
    }
}

public struct SlackSource: Codable, Sendable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let workspaceName: String
    public let userID: String
    public let channelID: String
    public let channelName: String
    public let repository: String
    public let intervalSeconds: Int
    public let enabled: Bool
    public let lastSuccess: Double?
    public let nextPoll: Double
    public let lastError: String?
    public let failures: Int
}

public struct SlackWorkspace: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let userID: String
    public let nextDiscovery: Double
    public let lastSuccess: Double?
    public let lastError: String?
    public let failures: Int
    public let pollIntervalSeconds: Int?
    public var intervalSeconds: Int { pollIntervalSeconds ?? 60 }
}
