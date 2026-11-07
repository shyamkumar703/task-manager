import CodexTransport
import Foundation
import Testing

private func shellClient(_ script: String, maxLineBytes: Int = 4 * 1024 * 1024) async throws -> CodexClient {
    let client = CodexClient()
    try await client.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], maxLineBytes: maxLineBytes)
    return client
}

@Test func handshakeDrainsStderrAndHandlesFragmentedFrames() async throws {
    let client = try await shellClient(#"""
        IFS= read -r request
        dd if=/dev/zero bs=4096 count=40 >&2 2>/dev/null
        printf '{"id":'
        printf '1,"result":{"userAgent":"fake-codex","platformOs":"macos"}}\n'
        IFS= read -r notification
        IFS= read -r request
        printf '{"method":"item/agentMessage/delta","params":{"delta":"hello"}}\n'
        printf '{"id":2,"result":{"ok":true}}\n'
        IFS= read -r hold
        """#)
    do {
        let result = try await client.initialize()
        #expect(result["userAgent"] == .string("fake-codex"))
        let reply = try await client.request("test")
        #expect(reply["ok"] == .bool(true))
        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.method == "item/agentMessage/delta")
        #expect(event?.params["delta"] == .string("hello"))
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test func responsesMatchRequestIDsOutOfOrder() async throws {
    let client = try await shellClient(#"""
        IFS= read -r request
        printf '{"method":"first-received","params":{}}\n'
        IFS= read -r request
        printf '{"id":2,"result":"second"}\n{"id":1,"result":"first"}\n'
        IFS= read -r hold
        """#)
    do {
        let first = Task { try await client.request("one") }
        var iterator = client.events.makeAsyncIterator()
        #expect(await iterator.next()?.method == "first-received")
        let second = try await client.request("two")
        #expect(second == .string("second"))
        #expect(try await first.value == .string("first"))
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test func timeoutCancellationAndDisconnectReleaseWaiters() async throws {
    let client = try await shellClient("while IFS= read -r request; do :; done")
    do {
        await #expect(throws: TransportError.self) {
            try await client.request("timeout", timeout: .milliseconds(30))
        }
        let request = Task { try await client.request("cancel", timeout: .seconds(30)) }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        let pending = Task { try await client.request("disconnect", timeout: .seconds(30)) }
        // The queued call must fail whether stop runs before or after it registers.
        await client.stop()
        await #expect(throws: TransportError.self) { try await pending.value }
    }
}

@Test func malformedAndOversizedFramesFailClosed() async throws {
    for (script, limit) in [("printf 'not-json\\n'", 4096), ("printf '123456789\\n'", 4)] {
        let client = try await shellClient(script, maxLineBytes: limit)
        await #expect(throws: (any Error).self) { try await client.request("test") }
        await client.stop()
    }
}

@Test func serverApprovalIsCancelledWithoutHumanApproval() async throws {
    let client = try await shellClient(#"""
        IFS= read -r request
        printf '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"command":"git push"}}\n'
        IFS= read -r response
        printf '{"id":1,"result":%s}\n' "$response"
        IFS= read -r hold
        """#)
    do {
        let response = try await client.request("test")
        #expect(response["id"] == .string("approval-1"))
        #expect(response["result"]?["decision"] == .string("cancel"))
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test func unknownServerRequestsAreRejected() async throws {
    let client = try await shellClient(#"""
        IFS= read -r request
        printf '{"id":"tool-1","method":"item/tool/call","params":{}}\n'
        IFS= read -r response
        printf '{"id":1,"result":%s}\n' "$response"
        IFS= read -r hold
        """#)
    do {
        let response = try await client.request("test")
        #expect(response["error"]?["code"] == .integer(-32601))
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test func blockedStdinDoesNotBlockRequestTimeoutOrStop() async throws {
    let client = try await shellClient("sleep 5")
    let start = ContinuousClock.now
    await #expect(throws: TransportError.self) {
        try await client.request("large", params: .string(String(repeating: "x", count: 1024 * 1024)), timeout: .milliseconds(40))
    }
    await client.stop()
    #expect(start.duration(to: .now) < .seconds(2))
}
