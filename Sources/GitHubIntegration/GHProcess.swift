import Darwin
import Foundation

public struct GHCommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data

    public init(exitCode: Int32, stdout: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
    }
}

public protocol GHCommandExecuting: Sendable {
    func run(arguments: [String]) async throws -> GHCommandResult
}

public enum GHProcessError: Error, Sendable, CustomStringConvertible {
    case notInstalled, timeout, outputLimit, invalidLimits

    public var description: String {
        switch self {
        case .notInstalled: "gh was not found. Install GitHub CLI and run gh auth login."
        case .timeout: "gh timed out while reading GitHub"
        case .outputLimit: "gh output exceeded the configured size limit"
        case .invalidLimits: "gh timeout and output limit must be positive"
        }
    }
}

/// Finite command execution. Blocking IO stays off Swift's cooperative executor.
public struct GHProcessRunner: GHCommandExecuting {
    private let executable: URL?
    private let timeout: Duration
    private let maxOutputBytes: Int

    public init(executable: URL? = nil, timeout: Duration = .seconds(30), maxOutputBytes: Int = 16 * 1024 * 1024) {
        self.executable = executable
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    public func run(arguments: [String]) async throws -> GHCommandResult {
        guard timeout > .zero, maxOutputBytes > 0 else { throw GHProcessError.invalidLimits }
        try Task.checkCancellation()
        let executable = try resolveExecutable()
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try execute(executable, arguments, cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func resolveExecutable() throws -> URL {
        if let executable { return executable }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let path = paths.map({ String($0) + "/gh" }).first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw GHProcessError.notInstalled
        }
        return URL(fileURLWithPath: path)
    }

    private func execute(_ executable: URL, _ arguments: [String], _ cancellation: CancellationFlag) throws -> GHCommandResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_PAGER"] = "cat"
        environment.removeValue(forKey: "GH_DEBUG")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForReading.close()
            try? errors.fileHandleForWriting.close()
        }
        if cancellation.isCancelled { throw CancellationError() }
        try process.run()
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        for descriptor in [outFD, errFD] {
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
                throw POSIXError(.EIO)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var stdout = Data()
        var open = Set([outFD, errFD])
        var bytes = [UInt8](repeating: 0, count: 4096)
        while !open.isEmpty || process.isRunning {
            if cancellation.isCancelled { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw GHProcessError.timeout }
            var descriptors = open.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP), revents: 0) }
            let ready = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), 20)
            }
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            for descriptor in descriptors where descriptor.revents != 0 {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor.fd, buffer.baseAddress, buffer.count)
                }
                if count == 0 { open.remove(descriptor.fd) }
                else if count > 0, descriptor.fd == outFD {
                    guard stdout.count + count <= maxOutputBytes else { throw GHProcessError.outputLimit }
                    stdout.append(contentsOf: bytes.prefix(count))
                } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                // stderr is drained but never persisted or returned: gh can print sensitive diagnostics.
            }
        }
        process.waitUntilExit()
        return GHCommandResult(exitCode: process.terminationStatus, stdout: stdout)
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}
