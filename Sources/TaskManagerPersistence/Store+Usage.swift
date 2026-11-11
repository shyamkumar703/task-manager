import Foundation
import TaskManagerCore

extension Store {
    public func registerUsageThread(threadID: String, taskID: String? = nil, sourceEventID: Int64? = nil, role: String, model: String?, provider: String?, effort: String? = nil, serviceTier: String? = nil, resumed: Bool = false) throws {
        try requireText(threadID, name: "Usage thread")
        try db.execute("""
            INSERT INTO usage_threads(thread_id, task_id, source_event_id, role, model, provider, effort, service_tier, resumed)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET model = excluded.model, provider = excluded.provider,
                effort = excluded.effort, service_tier = excluded.service_tier
            """, [threadID, taskID, sourceEventID.map(String.init), role, model ?? "unknown", provider ?? "unknown", effort, serviceTier, resumed ? "1" : "0"])
    }

    public func updateUsageModel(threadID: String, model: String) throws {
        try db.execute("UPDATE usage_threads SET model = ? WHERE thread_id = ?", [model, threadID])
    }

    /// Persist deltas from the thread-wide cumulative high-water mark. Never sum `last` events.
    /// `last` is used only to exclude pre-tracking history when first observing a resumed thread.
    @discardableResult public func recordUsage(threadID: String, turnID: String, total: TokenUsage, last: TokenUsage) throws -> Bool {
        try total.validate(); try last.validate()
        return try db.transaction {
            guard let thread = try db.query("SELECT * FROM usage_threads WHERE thread_id = ?", [threadID]).first else { throw ManagerError.notFound("Usage thread is not registered") }
            let previous: TokenUsage
            if let json = thread["counters"] { previous = try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8)) }
            else { previous = thread["resumed"] == "1" ? total.subtracting(last) : .zero }
            guard total.totalTokens > previous.totalTokens else { return false }
            guard total.inputTokens >= previous.inputTokens, total.cachedInputTokens >= previous.cachedInputTokens,
                  total.outputTokens >= previous.outputTokens, total.reasoningOutputTokens >= previous.reasoningOutputTokens,
                  total.cacheWriteInputTokens >= previous.cacheWriteInputTokens else { return false }
            let delta = total.subtracting(previous)
            try delta.validate()
            let model = thread["model"]!, provider = thread["provider"]!
            let configured = try db.query("SELECT price FROM usage_prices WHERE model = ? AND provider = ?", [model, provider]).first?["price"]
            let price = try configured ?? (provider == "openai" ? UsagePrice.standard[model].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } : nil)
            // No assumptions about cache-write duration, long-context premiums, or nonstandard tiers.
            let unpriceable = delta.cacheWriteInputTokens > 0 || last.inputTokens > 272_000 || ![nil, "default", "standard"].contains(thread["service_tier"])
            try db.execute("""
                INSERT INTO usage_turns(thread_id, turn_id, model, provider, effort, input_tokens, cached_tokens, cache_write_tokens, output_tokens, reasoning_tokens, total_tokens, price, unpriceable, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(thread_id, turn_id, model, provider) DO UPDATE SET
                    input_tokens = input_tokens + excluded.input_tokens,
                    cached_tokens = cached_tokens + excluded.cached_tokens,
                    cache_write_tokens = cache_write_tokens + excluded.cache_write_tokens,
                    output_tokens = output_tokens + excluded.output_tokens,
                    reasoning_tokens = reasoning_tokens + excluded.reasoning_tokens,
                    total_tokens = total_tokens + excluded.total_tokens,
                    price = COALESCE(price, excluded.price), unpriceable = MAX(unpriceable, excluded.unpriceable),
                    updated_at = excluded.updated_at
                """, [threadID, turnID, model, provider, thread["effort"], String(delta.inputTokens), String(delta.cachedInputTokens), String(delta.cacheWriteInputTokens), String(delta.outputTokens), String(delta.reasoningOutputTokens), String(delta.totalTokens), price, unpriceable ? "1" : "0", timestamp()])
            let json = String(decoding: try JSONEncoder().encode(total), as: UTF8.self)
            try db.execute("UPDATE usage_threads SET counters = ? WHERE thread_id = ?", [json, threadID])
            return true
        }
    }

    public func setUsagePrice(model: String, provider: String = "openai", price: UsagePrice) throws {
        try requireText(model, name: "Model"); try requireText(provider, name: "Provider"); try price.validate()
        let json = String(decoding: try JSONEncoder().encode(price), as: UTF8.self)
        try db.transaction {
            try db.execute("INSERT INTO usage_prices(model, provider, price) VALUES (?, ?, ?) ON CONFLICT(model, provider) DO UPDATE SET price = excluded.price", [model, provider, json])
            // Fill previously unknown rates; retain snapshots already attached to recorded usage.
            try db.execute("UPDATE usage_turns SET price = ? WHERE model = ? AND provider = ? AND price IS NULL", [json, model, provider])
        }
    }

    public func usage(taskID: String? = nil, sourceEventID: Int64? = nil) throws -> UsageReport {
        var filters: [String] = [], bindings: [String?] = []
        if let taskID { filters.append("t.task_id = ?"); bindings.append(taskID) }
        if let sourceEventID { filters.append("t.source_event_id = ?"); bindings.append(String(sourceEventID)) }
        let rows = try db.query("SELECT u.*, t.task_id, t.source_event_id, t.role FROM usage_turns u JOIN usage_threads t USING(thread_id)" + (filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND ")) + " ORDER BY u.updated_at, u.thread_id, u.turn_id", bindings)
        return try UsageReport(records: rows.map { row in
            let tokens = TokenUsage(inputTokens: Int64(row["input_tokens"]!)!, cachedInputTokens: Int64(row["cached_tokens"]!)!, cacheWriteInputTokens: Int64(row["cache_write_tokens"]!)!, outputTokens: Int64(row["output_tokens"]!)!, reasoningOutputTokens: Int64(row["reasoning_tokens"]!)!, totalTokens: Int64(row["total_tokens"]!)!)
            let price = try row["price"].map { try JSONDecoder().decode(UsagePrice.self, from: Data($0.utf8)) }
            return UsageRecord(threadID: row["thread_id"]!, turnID: row["turn_id"]!, taskID: row["task_id"], sourceEventID: row["source_event_id"].flatMap(Int64.init), role: row["role"]!, model: row["model"]!, provider: row["provider"]!, reasoningEffort: row["effort"], tokens: tokens, estimatedUSD: row["unpriceable"] == "1" ? nil : price?.estimate(tokens), priceSource: price?.source, updatedAt: row["updated_at"]!)
        })
    }
}
