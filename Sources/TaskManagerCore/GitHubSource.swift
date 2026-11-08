import Foundation

public struct GitHubSource: Codable, Sendable, Identifiable {
    public let id: String
    public let repository: String
    public let localRepository: String
    public let author: String
    public let intervalSeconds: Int
    public let enabled: Bool
    public let lastSuccess: Double?
    public let nextPoll: Double
    public let lastError: String?
    public let failures: Int
}
