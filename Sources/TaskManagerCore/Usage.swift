import Foundation

/// Codex counters: cached input is part of input, reasoning output is part of output.
public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int64
    public var cachedInputTokens: Int64
    public var cacheWriteInputTokens: Int64
    public var outputTokens: Int64
    public var reasoningOutputTokens: Int64
    public var totalTokens: Int64

    public init(inputTokens: Int64, cachedInputTokens: Int64 = 0, cacheWriteInputTokens: Int64 = 0, outputTokens: Int64, reasoningOutputTokens: Int64 = 0, totalTokens: Int64? = nil) {
        self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens; self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens ?? inputTokens + outputTokens
    }
    public static let zero = TokenUsage(inputTokens: 0, outputTokens: 0)
    public func validate() throws {
        guard [inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens, totalTokens].allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000_000 }),
              cachedInputTokens <= inputTokens, reasoningOutputTokens <= outputTokens,
              totalTokens == inputTokens + outputTokens else { throw ManagerError.invalid("Invalid token usage counters") }
    }
    public func subtracting(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: max(0, inputTokens - other.inputTokens), cachedInputTokens: max(0, cachedInputTokens - other.cachedInputTokens), cacheWriteInputTokens: max(0, cacheWriteInputTokens - other.cacheWriteInputTokens), outputTokens: max(0, outputTokens - other.outputTokens), reasoningOutputTokens: max(0, reasoningOutputTokens - other.reasoningOutputTokens), totalTokens: max(0, totalTokens - other.totalTokens))
    }
}

public struct UsagePrice: Codable, Sendable, Equatable {
    public let input: Double
    public let cachedInput: Double
    public let output: Double
    public let source: String
    public init(input: Double, cachedInput: Double, output: Double, source: String) {
        self.input = input; self.cachedInput = cachedInput; self.output = output; self.source = source
    }
    public func validate() throws {
        guard [input, cachedInput, output].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }) else { throw ManagerError.invalid("Rates must be finite nonnegative USD per million tokens") }
    }
    public func estimate(_ usage: TokenUsage) -> Double? {
        guard usage.cacheWriteInputTokens == 0 else { return nil }
        return (Double(max(0, usage.inputTokens - usage.cachedInputTokens)) * input + Double(usage.cachedInputTokens) * cachedInput + Double(usage.outputTokens) * output) / 1_000_000
    }
    /// Standard short-context API-equivalent rates, verified 2026-11-11. Exact model IDs only.
    public static let standard: [String: UsagePrice] = [
        "gpt-6-astra": .init(input: 10, cachedInput: 1, output: 50, source: "OpenAI standard short-context API rates, 2026-11-11"),
        "gpt-6.1-sol": .init(input: 2, cachedInput: 0.10, output: 10, source: "OpenAI standard short-context API rates, 2026-11-11"),
        "gpt-6.1-terra": .init(input: 1, cachedInput: 0.05, output: 5, source: "OpenAI standard short-context API rates, 2026-11-11"),
        "gpt-6-luna": .init(input: 0.10, cachedInput: 0.01, output: 0.50, source: "OpenAI standard short-context API rates, 2026-11-11"),
    ]
}

public struct UsageRecord: Codable, Sendable {
    public let threadID: String
    public let turnID: String
    public let taskID: String?
    public let sourceEventID: Int64?
    public let role: String
    public let model: String
    public let provider: String
    public let reasoningEffort: String?
    public let tokens: TokenUsage
    public let estimatedUSD: Double?
    public let priceSource: String?
    public let updatedAt: String
    public init(threadID: String, turnID: String, taskID: String?, sourceEventID: Int64?, role: String, model: String, provider: String, reasoningEffort: String?, tokens: TokenUsage, estimatedUSD: Double?, priceSource: String?, updatedAt: String) {
        self.threadID = threadID; self.turnID = turnID; self.taskID = taskID; self.sourceEventID = sourceEventID
        self.role = role; self.model = model; self.provider = provider; self.reasoningEffort = reasoningEffort
        self.tokens = tokens; self.estimatedUSD = estimatedUSD; self.priceSource = priceSource; self.updatedAt = updatedAt
    }
}

public struct UsageReport: Codable, Sendable {
    public let records: [UsageRecord]
    public init(records: [UsageRecord] = []) { self.records = records }
    public var totalTokens: Int64 { records.reduce(0) { $0 + $1.tokens.totalTokens } }
    public var estimatedUSD: Double { records.reduce(0) { $0 + ($1.estimatedUSD ?? 0) } }
    public var unpricedRecords: Int { records.filter { $0.estimatedUSD == nil }.count }
    public var hasUsage: Bool { !records.isEmpty }
    public func forRole(_ role: String?) -> UsageReport { .init(records: records.filter { role == nil || $0.role == role }) }
    private enum CodingKeys: String, CodingKey { case records, totalTokens, estimatedUSD, unpricedRecords, hasUsage }
    public init(from decoder: any Decoder) throws {
        records = try decoder.container(keyedBy: CodingKeys.self).decode([UsageRecord].self, forKey: .records)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(records, forKey: .records)
        try values.encode(totalTokens, forKey: .totalTokens)
        // No priced usage is unknown, not a zero-dollar total.
        try values.encode(hasUsage && unpricedRecords < records.count ? estimatedUSD : nil, forKey: .estimatedUSD)
        try values.encode(unpricedRecords, forKey: .unpricedRecords)
        try values.encode(hasUsage, forKey: .hasUsage)
    }
}
