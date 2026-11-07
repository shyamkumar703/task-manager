import Foundation
import Darwin

/// Blocking pipe IO is isolated on dispatch queues, never on the Swift cooperative pool.
/// Immutable pipe ownership plus the write/stop lock make this wrapper safe to share.
final class LineProcess: @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "task-manager.codex.stdin")
    private var stopped = false

    init(executable: URL, arguments: [String], environment: [String: String]?, maxLineBytes: Int) throws {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        lines = pair.stream
        continuation = pair.continuation
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let inputFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        // Parent must not retain the child's ends, or EOF may never arrive.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading
        let stderr = errors.fileHandleForReading
        let continuation = continuation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { try? stdout.close() }
            do {
                var buffer = Data()
                while let data = try Self.readChunk(stdout) {
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let frame = Data(buffer[..<newline])
                        guard frame.count <= maxLineBytes else { throw TransportError.oversizedMessage }
                        if !frame.isEmpty {
                            switch continuation.yield(frame) {
                            case .dropped: throw TransportError.backlogExceeded
                            case .terminated: return
                            case .enqueued: break
                            @unknown default: throw TransportError.disconnected
                            }
                        }
                        buffer.removeSubrange(...newline)
                    }
                    guard buffer.count <= maxLineBytes else { throw TransportError.oversizedMessage }
                }
                guard buffer.isEmpty else { throw TransportError.invalidMessage }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
                self?.stop()
            }
        }
        // Drain and discard stderr: it must neither deadlock the child nor accumulate secrets in logs.
        DispatchQueue.global(qos: .utility).async {
            defer { try? stderr.close() }
            while (try? Self.readChunk(stderr)) != nil {}
        }
    }

    private static func readChunk(_ handle: FileHandle) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let size = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if size == 0 { return nil }
            if size > 0 { return Data(bytes.prefix(size)) }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func write(_ data: Data, onFailure: @escaping @Sendable (any Error) -> Void) {
        writer.async { [self] in
            do {
                var offset = 0
                while offset < data.count {
                    let count: Int
                    let descriptor: Int32
                    let writeError: Int32
                    lock.lock()
                    guard !stopped, process.isRunning else {
                        lock.unlock()
                        throw TransportError.disconnected
                    }
                    descriptor = input.fileHandleForWriting.fileDescriptor
                    count = data.withUnsafeBytes { buffer in
                        Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), min(4096, data.count - offset))
                    }
                    writeError = errno
                    lock.unlock()
                    if count > 0 { offset += count; continue }
                    if count < 0, writeError == EINTR { continue }
                    if count < 0, writeError == EAGAIN || writeError == EWOULDBLOCK {
                        var ready = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                        _ = Darwin.poll(&ready, 1, 100)
                        continue
                    }
                    throw TransportError.disconnected
                }
            } catch { onFailure(error) }
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        try? input.fileHandleForWriting.close()
        continuation.finish()
        if process.isRunning {
            process.terminate()
            let process = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    deinit { stop() }
}
