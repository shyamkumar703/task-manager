import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import Testing

private actor FakeGitHub: GitHubHTTPTransport {
    var responses: [HTTPResponse]
    var requests: [URLRequest] = []

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    func get(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw ManagerError.invalid("Unexpected request") }
        return responses.removeFirst()
    }
}

private func response(_ json: String, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(data: Data(json.utf8), status: 200, headers: headers)
}

@Test func githubFetchesAllFeedbackTypesAndPreservesAssociations() async throws {
    let transport = FakeGitHub([
        response(#"[{"id":1,"body":"Validate inputs","html_url":"https://github.com/o/r/pull/7#issuecomment-1","updated_at":"v1","user":{"login":"reviewer"}}]"#,
                 headers: ["link": "<https://api.github.com/repos/o/r/issues/7/comments?page=2>; rel=\"next\""]),
        response(#"[{"id":2,"body":"More context","html_url":"https://github.com/o/r/pull/7#issuecomment-2","updated_at":"v1"}]"#),
        response(#"[{"id":1,"body":"Handle empty strings","html_url":"https://github.com/o/r/pull/7#discussion_r1","path":"Sources/main.swift","line":12,"updated_at":"v1"}]"#),
        response(#"[{"id":1,"body":"Please add tests","html_url":"https://github.com/o/r/pull/7#pullrequestreview-1","submitted_at":"v1","state":"CHANGES_REQUESTED"},{"id":2,"body":"Draft","html_url":"x","state":"PENDING"},{"id":3,"body":"","html_url":"x"}]"#),
    ])
    let client = try GitHubClient(transport: transport)
    let repository = try GitHubRepository("o/r")
    let events = try await client.feedback(in: repository, pr: 7)
    #expect(events.count == 4)
    #expect(Set(events.map(\.sourceID)).count == 4)
    #expect(events.allSatisfy { $0.associationKey == "github:o/r:pr:7" })
    #expect(events[2].body.contains("File: Sources/main.swift"))
    let requests = await transport.requests
    #expect(requests.count == 4)
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "api.github.com" })
    #expect(requests[1].url?.query?.contains("page=2") == true)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    let store = try Store(path: ":memory:")
    let task = try await store.createTask(goal: "Handle PR feedback", sourceKey: repository.associationKey(pr: 7))
    #expect(try await store.ingest(events) == 4)
    #expect(try await store.routeKnownEvents() == 4)
    #expect(try await store.messages(taskID: task.id).count == 4)
}

@Test func editedReviewsHaveNewRevisionsWithoutNewSubmissionTimestamp() async throws {
    func events(body: String) async throws -> [SourceEvent] {
        let review = "[{\"id\":1,\"body\":\"\(body)\",\"html_url\":\"https://github.com/o/r/pull/1\",\"submitted_at\":\"same\",\"state\":\"COMMENTED\"}]"
        let client = try GitHubClient(transport: FakeGitHub([response("[]"), response("[]"), response(review)]))
        return try await client.feedback(in: GitHubRepository("o/r"), pr: 1)
    }
    let original = try await events(body: "Original")
    let repeated = try await events(body: "Original")
    let edited = try await events(body: "Edited")
    #expect(original == repeated)
    #expect(original[0].sourceID == edited[0].sourceID)
    #expect(original[0].revision != edited[0].revision)
}

@Test func githubFailuresDoNotReturnPartialBatchesOrLeakResponseBodies() async throws {
    let denied = HTTPResponse(data: Data("sensitive server body".utf8), status: 403, headers: ["retry-after": "60"])
    let transport = FakeGitHub([response("[]"), denied])
    let client = try GitHubClient(transport: transport)
    do {
        _ = try await client.feedback(in: GitHubRepository("o/r"), pr: 1)
        Issue.record("Expected rate-limit error")
    } catch let error as GitHubError {
        #expect(error.description.contains("403"))
        #expect(error.description.contains("60"))
        #expect(!error.description.contains("sensitive"))
    }
    let endless = FakeGitHub([response("[]", headers: ["link": "<https://evil.example/>; rel=\"next\""])])
    let bounded = try GitHubClient(transport: endless, maxPages: 1)
    await #expect(throws: GitHubError.self) { try await bounded.feedback(in: GitHubRepository("o/r"), pr: 1) }
    #expect(await endless.requests.allSatisfy { $0.url?.host == "api.github.com" })
}

@Test func githubRejectsInvalidScopesAndFiltersPullAuthors() async throws {
    for slug in ["", "o", "o/r/extra", "../repo", "o/r?x=1", "o/r%2Fextra"] {
        #expect(throws: ManagerError.self) { try GitHubRepository(slug) }
    }
    let transport = FakeGitHub([response(#"[{"number":1,"title":"Mine","user":{"login":"Me"},"head":{"sha":"abc"}},{"number":2,"title":"Other","user":{"login":"other"},"head":{"sha":"def"}}]"#)])
    let client = try GitHubClient(transport: transport)
    let prs = try await client.openPullRequests(in: GitHubRepository("o/r"), author: "me")
    #expect(prs.map(\.number) == [1])
}
