import Foundation
import TaskManagerCore

enum UsagePresentation {
    static let roles: [(String?, String)] = [(nil, "All usage"), ("implementation", "Implementation"), ("exploration", "Exploration"), ("triage", "Coordinator triage"), ("discovery", "PR discovery")]
    static func money(_ amount: Double) -> String { String(format: "$%.4f", amount) }
    static func count(_ amount: Int64) -> String { amount.formatted(.number.locale(Locale(identifier: "en_US"))) }
    static func compact(_ report: UsageReport) -> String {
        guard report.hasUsage else { return "Usage: not recorded" }
        let cost = report.unpricedRecords == report.records.count ? "cost unknown" : "API est. " + money(report.estimatedUSD) + (report.unpricedRecords > 0 ? " + unpriced" : "")
        return "\(count(report.totalTokens)) tokens · \(cost)"
    }
    static func sections(_ report: UsageReport) -> [TaskInfoSection] {
        guard report.hasUsage else {
            return [.init(title: "USAGE & COST", text: "No usage recorded yet. Tracking starts with new Codex activity; historical tasks and mock workers have no recorded usage. Missing usage is not zero cost.", style: 3)]
        }
        let input = report.records.reduce(Int64(0)) { $0 + $1.tokens.inputTokens }
        let cached = report.records.reduce(Int64(0)) { $0 + $1.tokens.cachedInputTokens }
        let output = report.records.reduce(Int64(0)) { $0 + $1.tokens.outputTokens }
        let reasoning = report.records.reduce(Int64(0)) { $0 + $1.tokens.reasoningOutputTokens }
        let turns = Set(report.records.map { $0.threadID + ":" + $0.turnID }).count
        var text = "\(count(report.totalTokens)) total tokens across \(turns) observed \(turns == 1 ? "turn" : "turns")\nInput: \(count(input)) (\(count(cached)) cached)\nOutput: \(count(output)) (\(count(reasoning)) reasoning; already included in output)"
        text += report.unpricedRecords == report.records.count ? "\nEstimated API cost: unknown" : "\nEstimated API cost: \(money(report.estimatedUSD))" + (report.unpricedRecords > 0 ? " (priced portion only)" : "")
        if report.unpricedRecords > 0 { text += "\n\(report.unpricedRecords) usage records are unpriced: model/rate unavailable, unsupported tier, long context, or cache writes." }
        var sections = [TaskInfoSection(title: "USAGE & COST", text: text)]
        let groups = Dictionary(grouping: report.records) { $0.provider + " / " + $0.model }
        for name in groups.keys.sorted() {
            let records = groups[name]!
            let subset = UsageReport(records: records)
            let rates = Set(records.compactMap(\.priceSource)).sorted().joined(separator: "; ")
            let efforts = Set(records.compactMap(\.reasoningEffort)).sorted().joined(separator: ", ")
            sections.append(.init(title: name, text: compact(subset) + (efforts.isEmpty ? "" : "\nReasoning effort: " + efforts) + (rates.isEmpty ? "" : "\nRate: " + rates), style: 3))
        }
        sections.append(.init(title: "ESTIMATE BASIS", text: "API-equivalent token estimates, not your subscription bill. Excludes tool fees and compute. Tracking covers observed activity since this feature was enabled, including failed/interrupted turns. Rate snapshots are retained; unknown models are not treated as free. Configure a rate with the usage-price CLI command.", style: 3))
        return sections
    }
}
