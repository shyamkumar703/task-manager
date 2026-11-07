import Foundation

/// JSON-RPC client for a single owned app-server process. No agent thread starts implicitly.
public actor CodexClient {
    public struct Event: Sendable {
        public let method: String
        public let params: JSONValue
    }

    public nonisolated let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var process: LineProcess?
    private var reader: Task<Void, Never>?
    private var nextID: Int64 = 0
    private var pending: [Int64: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeouts: [Int64: Task<Void, Never>] = [:]
    private var started = false

    public init() {
        let pair = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(256))
        events = pair.stream
        eventContinuation = pair.continuation
    }

    public func start(executable: URL, arguments: [String] = ["app-server", "--listen", "stdio://"], environment: [String: String]? = nil, maxLineBytes: Int = 4 * 1024 * 1024) throws {
        guard !started else { throw TransportError.alreadyStarted }
        guard maxLineBytes > 0 else { throw TransportError.oversizedMessage }
        let child = try LineProcess(executable: executable, arguments: arguments, environment: environment, maxLineBytes: maxLineBytes)
        started = true
        process = child
        reader = Task { [weak self, lines = child.lines] in
            do {
                for try await line in lines {
                    guard let self else { return }
                    try await self.receive(line)
                }
                await self?.finish(TransportError.disconnected)
            } catch { await self?.finish(error) }
        }
    }

    public func initialize(timeout: Duration = .seconds(10)) async throws -> JSONValue {
        let response = try await request("initialize", params: .object([
            "clientInfo": .object(["name": .string("autonomous_task_manager"), "title": .string("Autonomous Task Manager"), "version": .string("0.1.0")]),
            "capabilities": .object(["experimentalApi": .bool(false)]),
        ]), timeout: timeout)
        guard response["userAgent"]?.string != nil else { throw TransportError.invalidMessage }
        try notify("initialized")
        return response
    }

    public func request(_ method: String, params: JSONValue = .object([:]), timeout: Duration = .seconds(10)) async throws -> JSONValue {
        try Task.checkCancellation()
        guard process != nil else { throw TransportError.disconnected }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send(.object(["id": .integer(id), "method": .string(method), "params": params]))
                    timeouts[id] = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) }
                        catch { return }
                        await self?.cancel(id: id, error: TransportError.timeout)
                    }
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id, error: CancellationError()) }
        }
    }

    public func notify(_ method: String, params: JSONValue = .object([:])) throws {
        try send(.object(["method": .string(method), "params": params]))
    }

    public func stop() {
        finish(TransportError.disconnected)
        reader?.cancel()
        reader = nil
    }

    private func send(_ value: JSONValue) throws {
        guard let process else { throw TransportError.disconnected }
        var data = try JSONEncoder().encode(value)
        data.append(10)
        guard data.count <= 4 * 1024 * 1024 else { throw TransportError.oversizedMessage }
        process.write(data) { [weak self] error in
            Task { await self?.finish(error) }
        }
    }

    private func receive(_ data: Data) throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object = message else { throw TransportError.invalidMessage }
        if let method = message["method"]?.string {
            if let id = message["id"] {
                // No server request can grant capabilities in the foundation release.
                // Explicitly cancel known approvals, and fail closed for every other request.
                let result: JSONValue?
                switch method {
                case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                    result = .object(["decision": .string("cancel")])
                case "item/permissions/requestApproval":
                    result = .object(["permissions": .object([:]), "scope": .string("turn")])
                default: result = nil
                }
                if let result { try send(.object(["id": id, "result": result])) }
                else {
                    try send(.object(["id": id, "error": .object(["code": .integer(-32601), "message": .string("Server requests are unavailable until interaction handling is enabled")])]))
                }
                try emit(Event(method: "client/requestDenied", params: .object(["method": .string(method)])))
            } else {
                try emit(Event(method: method, params: message["params"] ?? .null))
            }
            return
        }
        guard let id = message["id"]?.integer else { throw TransportError.invalidMessage }
        // Late responses after timeout/cancellation are harmless.
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        if let error = message["error"] {
            continuation.resume(throwing: TransportError.remote(code: error["code"]?.integer ?? -1, message: error["message"]?.string ?? "Unknown server error"))
        } else if let result = message["result"] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: TransportError.invalidMessage)
        }
    }

    private func emit(_ event: Event) throws {
        if case .dropped = eventContinuation.yield(event) { throw TransportError.backlogExceeded }
    }

    private func cancel(id: Int64, error: any Error) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func finish(_ error: any Error) {
        process?.stop()
        process = nil
        for timeout in timeouts.values { timeout.cancel() }
        timeouts.removeAll()
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.resume(throwing: error) }
        eventContinuation.finish()
    }

    deinit {
        reader?.cancel()
        process?.stop()
        for timeout in timeouts.values { timeout.cancel() }
        for request in pending.values { request.resume(throwing: TransportError.disconnected) }
        eventContinuation.finish()
    }
}
