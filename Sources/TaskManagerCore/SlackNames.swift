import Foundation

public struct SlackUserName: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Workspace-scoped display metadata. Raw event bodies and routing identities stay unchanged.
public struct SlackNameDirectory: Sendable {
    public let users: [String: String]
    public let channels: [String: String]
    public init(users: [String: String] = [:], channels: [String: String] = [:]) { self.users = users; self.channels = channels }
    public func user(_ id: String, workspace: String) -> String { users[workspace + ":" + id] ?? id }
    public func channel(_ id: String, workspace: String, fallback: String? = nil) -> String {
        let name = channels[workspace + ":" + id] ?? fallback ?? id
        if name.hasPrefix("DM with ") { return "DM with " + user(String(name.dropFirst(8)), workspace: workspace) }
        return name == id ? id : "#" + name.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }
    public func workspace(of source: IncomingSource) -> String? {
        guard source.integration == "slack" else { return nil }
        let parts = source.sourceID.split(separator: ":")
        return parts.count == 3 ? String(parts[0]) : nil
    }
    public func author(of source: IncomingSource) -> String? {
        guard let workspace = workspace(of: source), let first = source.body.components(separatedBy: "\n").first, first.hasPrefix("Author: ") else { return nil }
        return user(String(first.dropFirst(8)), workspace: workspace)
    }
    public func channel(of source: IncomingSource) -> String? {
        guard let workspace = workspace(of: source) else { return nil }
        let parts = source.sourceID.split(separator: ":")
        return channel(String(parts[1]), workspace: workspace, fallback: source.slackContext?.channelName)
    }
    public func body(of source: IncomingSource) -> String {
        guard let workspace = workspace(of: source) else { return source.body }
        return render(source.body, workspace: workspace, channelFallback: source.slackContext?.channelName)
    }
    public func preview(of source: IncomingSource) -> String {
        guard workspace(of: source) != nil, source.body.hasPrefix("Author: "), let range = source.body.range(of: "\n\n") else { return body(of: source) }
        return render(String(source.body[range.upperBound...]), workspace: workspace(of: source)!)
    }
    public func envelope(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"slack://[^\s]+"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text), let url = URLComponents(string: String(text[range])),
              let workspace = url.queryItems?.first(where: { $0.name == "team" })?.value else { return text }
        return render(text, workspace: workspace)
    }
    public func render(_ text: String, workspace: String, channelFallback: String? = nil) -> String {
        func replace(_ input: String, pattern: String, value: (NSTextCheckingResult, String) -> String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
            var result = input
            for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: value(match, input))
            }
            return result
        }
        func capture(_ match: NSTextCheckingResult, _ text: String, _ group: Int) -> String? {
            guard let range = Range(match.range(at: group), in: text) else { return nil }; return String(text[range])
        }
        var result = replace(text, pattern: #"(?m)^Author: ([UW][A-Z0-9]+)$"#) { match, input in
            "Author: " + user(capture(match, input, 1)!, workspace: workspace)
        }
        result = replace(result, pattern: #"(?m)^Channel: ([CDG][A-Z0-9]+)$"#) { match, input in
            "Channel: " + channel(capture(match, input, 1)!, workspace: workspace, fallback: channelFallback)
        }
        result = replace(result, pattern: #"<@([UW][A-Z0-9]+)(?:\|([^>]+))?>"#) { match, input in
            let id = capture(match, input, 1)!
            return "@" + (users[workspace + ":" + id] ?? capture(match, input, 2) ?? id)
        }
        return replace(result, pattern: #"<#([CDG][A-Z0-9]+)(?:\|([^>]+))?>"#) { match, input in
            channel(capture(match, input, 1)!, workspace: workspace, fallback: capture(match, input, 2))
        }
    }
}
