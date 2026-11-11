import Foundation
import SlackIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private actor NameTransport: SlackHTTPTransport {
    var requests: [URLRequest] = []
    let response: SlackHTTPResponse
    init(_ json: String, status: Int = 200, retryAfter: Double? = nil) { response = .init(data: Data(json.utf8), status: status, retryAfter: retryAfter) }
    func get(_ request: URLRequest) -> SlackHTTPResponse { requests.append(request); return response }
}

private actor SelfNameTransport: SlackHTTPTransport {
    var paths: [String] = []
    let workspace: String
    init(workspace: String = "T1") { self.workspace = workspace }
    func get(_ request: URLRequest) throws -> SlackHTTPResponse {
        paths.append(request.url!.path)
        let json: String
        if request.url?.path == "/api/users.info" { json = #"{"ok":false,"error":"missing_scope"}"# }
        else {
            #expect(request.httpMethod == "POST")
            json = "{\"ok\":true,\"team_id\":\"\(workspace)\",\"user_id\":\"U1\",\"user\":\"shyam\"}"
        }
        return SlackHTTPResponse(data: Data(json.utf8))
    }
}

@Test func connectedUserResolvesWithoutUsersReadAndCanRetryPriorFailureImmediately() async throws {
    let root = try nameRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    try await store.ensureSlackWorkspace(id: "T1", name: "Personal", userID: "U1")
    try await store.ingest([.init(integration: "slack", sourceID: "T1:C1:1", revision: "1", associationKey: "slack:T1:C1:thread:1", body: "Author: U1\nChannel: C1\n\nHi", url: "slack://message")], repository: root)
    try await store.deferSlackUserName(workspaceID: "T1", userID: "U1", until: Date().addingTimeInterval(3600))
    #expect(try await store.slackNameCandidates().isEmpty)
    try await store.retryMissingSlackNames()
    let transport = SelfNameTransport()
    let resolver = SlackNameResolver(store: store, factory: { _, _ in SlackClient(token: "fixture", transport: transport) })
    #expect(try await resolver.refresh() == 1)
    #expect(try await store.slackNames().user("U1", workspace: "T1") == "shyam")
    #expect(await transport.paths == ["/api/users.info", "/api/auth.test"])
    let wrongWorkspace = SlackClient(token: "fixture", transport: SelfNameTransport(workspace: "OTHER"))
    await #expect(throws: SlackError.self) { _ = try await wrongWorkspace.authenticatedUserName(workspaceID: "T1", userID: "U1") }
}

private func nameRoot() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("slack-names-\(UUID())").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test func slackUserLookupPrefersDisplayNameAndFallsBackThroughProfileNames() async throws {
    for (json, expected) in [
        (#"{"ok":true,"user":{"id":"U1","name":"handle","real_name":"Real","profile":{"display_name":" Shyam ","real_name":"Profile"}}}"#, "Shyam"),
        (#"{"ok":true,"user":{"id":"U1","name":"handle","real_name":"Real","profile":{"display_name":"","real_name":"Profile"}}}"#, "Profile"),
        (#"{"ok":true,"user":{"id":"U1","name":"handle","real_name":"Real"}}"#, "Real"),
        (#"{"ok":true,"user":{"id":"U1","name":"handle"}}"#, "handle"),
        (#"{"ok":true,"user":{"id":"U1"}}"#, "U1"),
    ] {
        let transport = NameTransport(json)
        let name = try await SlackClient(token: "fixture", transport: transport).userName(id: "U1")
        #expect(name.name == expected)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/api/users.info")
        #expect(request.url?.query == "user=U1")
        #expect(request.url?.query?.contains("token") == false)
    }
}

@Test func slackNamesHandleMissingScopeRateLimitsAndMismatchedProfiles() async throws {
    let scope = SlackClient(token: "fixture", transport: NameTransport(#"{"ok":false,"error":"missing_scope"}"#))
    do { _ = try await scope.userName(id: "U1"); Issue.record("Expected missing scope") }
    catch { #expect(String(describing: error).contains("users:read")) }
    let limited = SlackClient(token: "fixture", transport: NameTransport("", status: 429, retryAfter: 120))
    do { _ = try await limited.userName(id: "U1"); Issue.record("Expected rate limit") }
    catch SlackError.rateLimited(let seconds) { #expect(seconds == 120) }
    let wrong = SlackClient(token: "fixture", transport: NameTransport(#"{"ok":true,"user":{"id":"U2","name":"Wrong"}}"#))
    await #expect(throws: SlackError.self) { _ = try await wrong.userName(id: "U1") }
}

@Test func slackNamesRenderHistoricalSourcesMentionsAndPreviewWithoutChangingRawData() async throws {
    let root = try nameRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    _ = try await store.addSlackSource(workspaceID: "T1", workspaceName: "Personal", userID: "U1", channelID: "C1", channelName: "feat-folders")
    let raw = "Author: U1\nChannel: C1\n\n🧑🏽‍💻 <@U1> ask <@U2> in <#C1|old-name> and <#C2|general>."
    try await store.ingest([.init(integration: "slack", sourceID: "T1:C1:1", revision: "same", associationKey: "slack:T1:C1:thread:1", body: raw, url: "slack://channel?team=T1&id=C1&message=1")], repository: root)
    let source = try #require(await store.sources().first)
    try await store.cacheSlackUserName(workspaceID: "T1", user: .init(id: "U1", name: "Shyam"))
    try await store.cacheSlackUserName(workspaceID: "T2", user: .init(id: "U1", name: "Other workspace"))
    let names = try await store.slackNames()
    let rendered = names.body(of: source)
    #expect(rendered.contains("Author: Shyam\nChannel: #feat-folders"))
    #expect(rendered.contains("🧑🏽‍💻 @Shyam ask @U2 in #feat-folders and #general"))
    #expect(names.preview(of: source).hasPrefix("🧑🏽‍💻 @Shyam"))
    #expect(names.envelope("Incoming slack request\nSource: \(source.url)\n" + raw).contains("Author: Shyam"))
    #expect(names.user("U1", workspace: "T2") == "Other workspace")
    #expect(try await store.source(source.id).body == raw)
    #expect(try await store.source(source.id).revision == "same")
    let reopened = try Store(path: root + "/state.sqlite")
    #expect(try await reopened.slackNames().author(of: source) == "Shyam")
    #expect(SlackNameDirectory().body(of: source).contains("Author: U1"))
    #expect(SlackNameDirectory(users: ["T1:U1": "Shyam"]).channel("D1", workspace: "T1", fallback: "DM with U1") == "DM with Shyam")
}

@Test func slackNameResolverCachesBackfillsAndIsolatesLookupFailuresFromPolling() async throws {
    let root = try nameRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    for workspace in ["T1", "T2"] {
        try await store.ensureSlackWorkspace(id: workspace, name: workspace, userID: workspace == "T1" ? "U0" : "U1")
        try await store.ingest([.init(integration: "slack", sourceID: "\(workspace):C1:1", revision: "1", associationKey: "slack:\(workspace):C1:thread:1", body: "Author: U1\nChannel: C1\n\nHi", url: "slack://message")], repository: root)
    }
    let failed = NameTransport(#"{"ok":false,"error":"missing_scope"}"#)
    let healthy = NameTransport(#"{"ok":true,"user":{"id":"U1","profile":{"display_name":"Healthy"}}}"#)
    let resolver = SlackNameResolver(store: store, factory: { workspace, _ in
        SlackClient(token: "fixture", transport: workspace == "T1" ? failed : healthy)
    })
    let now = Date()
    #expect(try await resolver.refresh(now: now) == 1)
    #expect(try await resolver.refresh(now: now) == 0)
    #expect(await healthy.requests.count == 1)
    #expect(await failed.requests.count == 1)
    #expect(try await store.slackNames().user("U1", workspace: "T2") == "Healthy")
    #expect(try await store.sources().allSatisfy { $0.disposition == .pending })
    try await store.deferSlackUserName(workspaceID: "T2", userID: "U1", until: now.addingTimeInterval(7200))
    #expect(try await store.slackNames().user("U1", workspace: "T2") == "Healthy")
    #expect(try await store.slackNameCandidates(now: now.addingTimeInterval(90000)).count == 2)
}
