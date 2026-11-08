import CryptoKit
import Darwin
import Foundation

/// Local RFC 6455 transport. The Unix socket lives in a mode-0700 directory.
final class UnixWebSocket: @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let fd: Int32
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "task-manager.codex.websocket.write")
    private var stopped = false
    private let limit = 4 * 1024 * 1024

    init(path: String) throws {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        lines = pair.stream; continuation = pair.continuation
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.disconnected }
        do {
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw TransportError.invalidMessage }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw TransportError.disconnected }
            var enabled: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            try Self.writeAll(fd, Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
            var header = Data()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard header.count < 16384 else { throw TransportError.oversizedMessage }
                header.append(try Self.readExactly(fd, 1))
            }
            let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let text = String(decoding: header, as: UTF8.self)
            guard text.hasPrefix("HTTP/1.1 101 "), text.lowercased().contains("sec-websocket-accept: \(expected.lowercased())") else { throw TransportError.invalidMessage }
            timeout.tv_sec = 0
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        } catch { Darwin.close(fd); throw error }
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { stop(); Darwin.close(fd) }
            do {
                var message = Data(); var fragmented = false
                while true {
                    let header = try Self.readExactly(fd, 2)
                    let final = header[0] & 0x80 != 0, opcode = header[0] & 0x0f
                    guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw TransportError.invalidMessage }
                    var length = UInt64(header[1] & 0x7f)
                    if length == 126 { length = try Self.readExactly(fd, 2).reduce(0) { $0 << 8 | UInt64($1) } }
                    else if length == 127 { length = try Self.readExactly(fd, 8).reduce(0) { $0 << 8 | UInt64($1) } }
                    guard length <= limit, message.count + Int(length) <= limit else { throw TransportError.oversizedMessage }
                    let body = try Self.readExactly(fd, Int(length))
                    if opcode >= 8 {
                        guard final, length <= 125 else { throw TransportError.invalidMessage }
                        if opcode == 8 { break }
                        if opcode == 9 { sendFrame(body, opcode: 10) { _ in } }
                        else if opcode != 10 { throw TransportError.invalidMessage }
                        continue
                    }
                    guard (opcode == 1 && !fragmented) || (opcode == 0 && fragmented) else { throw TransportError.invalidMessage }
                    message.append(body); fragmented = !final
                    if final {
                        guard String(data: message, encoding: .utf8) != nil else { throw TransportError.invalidMessage }
                        switch continuation.yield(message) {
                        case .dropped: throw TransportError.backlogExceeded
                        case .terminated: return
                        default: break
                        }
                        message = Data()
                    }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }

    func write(_ data: Data, completion: @escaping @Sendable (any Error) -> Void) {
        sendFrame(data, opcode: 1) { error in if let error { completion(error) } }
    }

    private func sendFrame(_ data: Data, opcode: UInt8, completion: @escaping @Sendable ((any Error)?) -> Void) {
        writer.async { [self] in
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { completion(TransportError.disconnected); return }
            do {
                var frame = Data([0x80 | opcode])
                if data.count < 126 { frame.append(0x80 | UInt8(data.count)) }
                else if data.count <= 65535 {
                    frame.append(0x80 | 126); frame.append(UInt8(data.count >> 8)); frame.append(UInt8(data.count & 255))
                } else {
                    frame.append(0x80 | 127)
                    for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(data.count) >> shift) & 255)) }
                }
                let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
                frame.append(contentsOf: mask)
                frame.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
                try Self.writeAll(fd, frame); completion(nil)
            } catch { completion(error) }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped = true
        shutdown(fd, SHUT_RDWR); continuation.finish()
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw TransportError.disconnected }; offset += n
            }
        }
        return result
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw TransportError.disconnected }; offset += n
            }
        }
    }
}
