import CryptoKit
import Foundation
import TaskManagerCore

public struct SlackHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let retryAfter: Double?
    public init(data: Data, status: Int = 200, retryAfter: Double? = nil) { self.data = data; self.status = status; self.retryAfter = retryAfter }
}
public protocol SlackHTTPTransport: Sendable { func get(_ request: URLRequest) async throws -> SlackHTTPResponse }
public struct SlackURLTransport: SlackHTTPTransport {
    public init() {}
    public func get(_ request: URLRequest) async throws -> SlackHTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SlackError.unavailable }
            return SlackHTTPResponse(data: data, status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        } catch is CancellationError { throw CancellationError() }
        catch { throw SlackError.unavailable }
    }
}
public enum SlackError: Error, Sendable, CustomStringConvertible {
    case unavailable, rejected(String), rateLimited(Double), pageLimit
    public var description: String {
        switch self {
        case .unavailable: "Could not reach Slack"
        case .rejected(let code): "Slack rejected the read request: \(code). Check connection permissions."
        case .rateLimited(let seconds): "Slack rate limit; retry after \(Int(seconds)) seconds"
        case .pageLimit: "Slack pagination/thread safety limit reached; no partial poll committed"
        }
    }
}

public struct SlackClient: Sendable {
    private let token: String
    private let transport: any SlackHTTPTransport
    private let maxPages: Int
    public init(token: String, transport: any SlackHTTPTransport = SlackURLTransport(), maxPages: Int = 100) {
        self.token = token; self.transport = transport; self.maxPages = maxPages
    }
    private struct Metadata: Decodable { let next_cursor: String? }
    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let error: String?
        let needed: String?
        let channels: [T]?
        let messages: [T]?
        let response_metadata: Metadata?
        let has_more: Bool?
    }
    private func pages<T: Decodable>(method: String, query: [URLQueryItem]) async throws -> [T] {
        var cursor = "", seen = Set<String>(), values: [T] = []
        for _ in 0..<maxPages {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://slack.com/api/" + method)!
            url.queryItems = query + [URLQueryItem(name: "limit", value: "200")] + (cursor.isEmpty ? [] : [URLQueryItem(name: "cursor", value: cursor)])
            var request = URLRequest(url: url.url!)
            request.httpMethod = "GET"; request.timeoutInterval = 30
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let response = try await transport.get(request)
            if response.status == 429 { throw SlackError.rateLimited(min(86400, max(1, response.retryAfter ?? 60))) }
            guard response.status == 200, response.data.count <= 16 * 1024 * 1024 else { throw SlackError.unavailable }
            guard let result = try? JSONDecoder().decode(Envelope<T>.self, from: response.data) else { throw SlackError.unavailable }
            guard result.ok else {
                let allowed = ["missing_scope", "invalid_auth", "token_revoked", "token_expired", "not_in_channel", "channel_not_found", "account_inactive", "not_allowed_token_type"]
                let code = allowed.contains(result.error ?? "") ? result.error! : "request_failed"
                let scopes = Set(["channels:history", "groups:history", "im:history", "mpim:history", "channels:read", "groups:read", "im:read", "mpim:read"])
                let needed = (result.needed ?? "").split(separator: ",").map(String.init).filter { scopes.contains($0) }
                throw SlackError.rejected(method + ": " + code + (needed.isEmpty ? "" : "; scope options: " + needed.joined(separator: ", ")))
            }
            guard let batch = result.channels ?? result.messages else { throw SlackError.unavailable }
            values += batch
            cursor = result.response_metadata?.next_cursor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if cursor.isEmpty {
                guard result.has_more != true else { throw SlackError.pageLimit }
                return values
            }
            guard seen.insert(cursor).inserted else { throw SlackError.pageLimit }
        }
        throw SlackError.pageLimit
    }
    public func conversations() async throws -> [SlackConversation] {
        struct Channel: Decodable { let id: String; let name: String?; let user: String?; let is_im: Bool?; let is_mpim: Bool?; let is_archived: Bool?; let is_member: Bool? }
        let channels: [Channel] = try await pages(method: "conversations.list", query: [URLQueryItem(name: "types", value: "public_channel,private_channel,im,mpim"), URLQueryItem(name: "exclude_archived", value: "true")])
        return channels.filter { $0.is_archived != true }.map {
            let dm = $0.is_im == true || $0.is_mpim == true
            return SlackConversation(id: $0.id, name: $0.name ?? $0.user.map { "DM with " + $0 } ?? $0.id, isDM: dm)
        }
    }
    private struct Message: Decodable {
        struct Edited: Decodable { let ts: String }
        let ts: String; let text: String?; let user: String?; let bot_id: String?; let subtype: String?
        let thread_ts: String?; let reply_count: Int?; let edited: Edited?
    }
    /// Fetch complete bounded snapshots, including replies to old roots. Hashes catch edits;
    /// a new reply is its own event and never duplicates its parent message.
    public func feedback(workspace: String, channel: String) async throws -> [SourceEvent] {
        let roots: [Message] = try await pages(method: "conversations.history", query: [URLQueryItem(name: "channel", value: channel)])
        let threads = roots.filter { ($0.reply_count ?? 0) > 0 && ($0.thread_ts == nil || $0.thread_ts == $0.ts) }
        guard threads.count <= 200 else { throw SlackError.pageLimit }
        var messages = roots
        for root in threads {
            let replies: [Message] = try await pages(method: "conversations.replies", query: [URLQueryItem(name: "channel", value: channel), URLQueryItem(name: "ts", value: root.ts)])
            messages += replies
        }
        let rootText = Dictionary(roots.map { ($0.ts, $0.text ?? "") }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return messages.compactMap { message in
            guard let text = message.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.bot_id == nil, !["bot_message", "message_deleted", "channel_join", "channel_leave"].contains(message.subtype ?? "") else { return nil }
            let root = message.thread_ts ?? message.ts
            let revisionInput = [text, message.edited?.ts ?? "", message.user ?? "", message.subtype ?? ""].joined(separator: "\n")
            let revision = SHA256.hash(data: Data(revisionInput.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(message.ts + ":" + revision).inserted else { return nil }
            let context = root != message.ts ? rootText[root].map { "\nThread context: " + String($0.prefix(4000)) } ?? "" : ""
            return SourceEvent(integration: "slack", sourceID: "\(workspace):\(channel):\(message.ts)", revision: revision,
                associationKey: "slack:\(workspace):\(channel):thread:\(root)",
                body: "Author: \(message.user ?? "unknown")\nChannel: \(channel)\(context)\n\n\(text)",
                url: "slack://channel?team=\(workspace)&id=\(channel)&message=\(message.ts)")
        }
    }
}
