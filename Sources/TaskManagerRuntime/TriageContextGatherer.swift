import Foundation
import GitHubIntegration
import SlackIntegration
import TaskManagerCore
import TaskManagerPersistence

public protocol TriageContextGathering: Sendable {
    func gather(event: IncomingSource, candidates: [TriageCandidate]) async throws -> [String]
}

/// Bounded source reads. Results are evidence, never new requests or authorization.
public struct TriageContextGatherer: TriageContextGathering {
    private let store: Store
    public init(store: Store) { self.store = store }

    public func gather(event: IncomingSource, candidates: [TriageCandidate]) async throws -> [String] {
        var evidence: [String] = []
        if event.integration == "slack" {
            let parts = event.sourceID.split(separator: ":").map(String.init)
            if parts.count == 3, let source = try await store.slackSources().first(where: {
                $0.enabled && $0.workspaceID == parts[0] && $0.channelID == parts[1]
            }) {
                do {
                    let client = SlackClient(token: try SlackConnection.token(workspaceID: source.workspaceID, userID: source.userID))
                    let thread = event.associationKey.split(separator: ":").last.map(String.init)
                    var lookups: [String?] = [nil]
                    if let thread, thread != parts[2] { lookups.append(thread) }
                    for selectedThread in lookups {
                        do {
                            let messages = try await client.routingMessages(channel: source.channelID, before: parts[2], thread: selectedThread)
                            let data = try JSONEncoder().encode(messages)
                            evidence.append("Slack \(source.workspaceName)/\(source.channelName) \(selectedThread == nil ? "preceding channel messages" : "thread messages") (up to 50): " + String(decoding: data, as: UTF8.self))
                        } catch is CancellationError { throw CancellationError() }
                        catch { evidence.append("Slack context read failed: \(error)") }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { evidence.append("Slack connection unavailable: \(error)") }
            } else { evidence.append("No enabled Slack connection found for this source.") }
        }
        // Compare known projects; a sole project or PR is not sufficient evidence of intent.
        let roots = event.repository.isEmpty ? Array(Set((event.availableRepositories ?? []) + candidates.map(\.repository))).sorted() : [event.repository]
        for root in roots.prefix(4) {
            try Task.checkCancellation()
            do {
                guard let remote = try await GitHubContextResolver.git(root, ["remote", "get-url", "origin"]),
                      let repository = GitHubDiscovery.repository(remote: remote) else {
                    evidence.append("Project \(root): no GitHub origin identified."); continue
                }
                let client = try GitHubClient()
                for state in ["open", "closed"] {
                    let pulls = try await client.recentPullRequests(in: repository, state: state)
                    let summaries = pulls.prefix(12).map {
                        "#\($0.number) \($0.title) [\($0.head.ref ?? "unknown branch")] \(String(($0.body ?? "").prefix(1500)))"
                    }
                    evidence.append("GitHub \(repository.slug), local project \(root), recent \(state) PRs: " + (summaries.isEmpty ? "none" : summaries.joined(separator: "\n")))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { evidence.append("GitHub context read for \(root) failed: \(error)") }
        }
        if roots.count > 4 { evidence.append("Lookup budget reached: inspected 4 of \(roots.count) known projects.") }
        return evidence
    }
}
