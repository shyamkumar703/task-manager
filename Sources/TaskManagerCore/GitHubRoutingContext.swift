public struct GitHubRoutingContext: Codable, Sendable {
    public let repository: String
    public let pullRequest: Int
    public let headBranch: String
    public let headSHA: String
    public let headRepository: String?
    public let checkout: String?
    public let checkoutSHA: String?
    public let owningTaskID: String?

    public init(repository: String, pullRequest: Int, headBranch: String, headSHA: String, headRepository: String?, checkout: String? = nil, checkoutSHA: String? = nil, owningTaskID: String? = nil) {
        self.repository = repository; self.pullRequest = pullRequest; self.headBranch = headBranch; self.headSHA = headSHA; self.headRepository = headRepository; self.checkout = checkout; self.checkoutSHA = checkoutSHA; self.owningTaskID = owningTaskID
    }
}
