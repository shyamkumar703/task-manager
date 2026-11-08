import Foundation
import GitHubIntegration
import TaskManagerCore
import Testing

private actor FakeGHCommand: GHCommandExecuting {
    private var results: [GHCommandResult]
    var arguments: [[String]] = []
    init(_ outputs: [(Int32, String)]) {
        results = outputs.map { GHCommandResult(exitCode: $0.0, stdout: Data($0.1.utf8)) }
    }
    func run(arguments: [String]) throws -> GHCommandResult {
        self.arguments.append(arguments)
        guard !results.isEmpty else { throw ManagerError.invalid("Unexpected gh invocation") }
        return results.removeFirst()
    }
}

@Test func ghTransportUsesExistingAuthExplicitGETAndBoundedPagination() async throws {
    let first = "HTTP/2.0 200 OK\r\nLink: <https://api.github.com/repos/o/r/pulls?page=2>; rel=\"next\"\r\n\r\n[{\"number\":1,\"title\":\"First\",\"user\":{\"login\":\"me\"},\"head\":{\"sha\":\"abc\"}}]"
    let second = "HTTP/2.0 200 OK\nContent-Type: application/json\n\n[{\"number\":2,\"title\":\"Second\",\"user\":{\"login\":\"me\"},\"head\":{\"sha\":\"def\"}}]"
    let runner = FakeGHCommand([(0, first), (0, second)])
    let client = try GitHubClient(transport: GitHubCLITransport(runner: runner))
    let pulls = try await client.openPullRequests(in: GitHubRepository("o/r"), author: "me")
    #expect(pulls.map(\.number) == [1, 2])
    let commands = await runner.arguments
    #expect(commands.count == 2)
    #expect(commands[0].prefix(6) == ["api", "--hostname", "github.com", "--method", "GET", "--include"])
    #expect(commands[0].last == "/repos/o/r/pulls?state=open&per_page=100&page=1")
    #expect(commands[1].last == "/repos/o/r/pulls?state=open&per_page=100&page=2")
    #expect(commands.allSatisfy { !$0.contains("--paginate") && !$0.contains(where: { $0.hasPrefix("Authorization:") }) })
}

@Test func ghHTTPFailuresKeepRateLimitInformation() async throws {
    let runner = FakeGHCommand([(1, "HTTP/2.0 403 Forbidden\r\nRetry-After: 60\r\n\r\n{\"message\":\"sensitive response\"}")])
    let client = try GitHubClient(transport: GitHubCLITransport(runner: runner))
    do {
        _ = try await client.openPullRequests(in: GitHubRepository("o/r"), author: "me")
        Issue.record("Expected HTTP failure")
    } catch let error as GitHubError {
        #expect(error.description.contains("403"))
        #expect(error.description.contains("60"))
        #expect(!error.description.contains("sensitive"))
    }
}

@Test func ghRejectsMutationsForeignHostsAndManualCredentialsBeforeLaunching() async throws {
    let runner = FakeGHCommand([])
    let transport = GitHubCLITransport(runner: runner)
    for url in ["https://evil.example/repos/o/r/pulls", "http://api.github.com/repos/o/r/pulls", "https://api.github.com/graphql"] {
        let request = URLRequest(url: try #require(URL(string: url)))
        await #expect(throws: ManagerError.self) { try await transport.get(request) }
    }
    var write = URLRequest(url: URL(string: "https://api.github.com/repos/o/r/issues/1/comments")!)
    write.httpMethod = "POST"
    let mutation = write
    await #expect(throws: ManagerError.self) { try await transport.get(mutation) }
    var authenticated = URLRequest(url: URL(string: "https://api.github.com/repos/o/r/pulls")!)
    authenticated.setValue("Bearer fixture-secret", forHTTPHeaderField: "Authorization")
    let credentialRequest = authenticated
    await #expect(throws: ManagerError.self) { try await transport.get(credentialRequest) }
    #expect(await runner.arguments.isEmpty)
}

@Test func ghMissingHTTPResponseProducesActionableFailure() async throws {
    let request = URLRequest(url: URL(string: "https://api.github.com/repos/o/r/pulls")!)
    let failed = GitHubCLITransport(runner: FakeGHCommand([(1, "")]))
    await #expect(throws: GitHubError.self) { try await failed.get(request) }
    let malformed = GitHubCLITransport(runner: FakeGHCommand([(0, "not an HTTP response")]))
    await #expect(throws: ManagerError.self) { try await malformed.get(request) }
}

@Test func ghProcessDrainsStderrAndKeepsExitStatus() async throws {
    let runner = GHProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"))
    let result = try await runner.run(arguments: ["-c", "dd if=/dev/zero bs=4096 count=40 >&2 2>/dev/null; printf 'fixture-output'; exit 7"])
    #expect(result.exitCode == 7)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "fixture-output")
}

@Test func ghProcessTimeoutOutputLimitAndCancellationAreBounded() async throws {
    let executable = URL(fileURLWithPath: "/bin/sh")
    let timeout = GHProcessRunner(executable: executable, timeout: .milliseconds(50))
    await #expect(throws: GHProcessError.self) { try await timeout.run(arguments: ["-c", "exec sleep 5"]) }
    let bounded = GHProcessRunner(executable: executable, maxOutputBytes: 8)
    await #expect(throws: GHProcessError.self) { try await bounded.run(arguments: ["-c", "printf '123456789'"]) }
    let runner = GHProcessRunner(executable: executable)
    let task = Task { try await runner.run(arguments: ["-c", "exec sleep 5"]) }
    try await Task.sleep(for: .milliseconds(30))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
