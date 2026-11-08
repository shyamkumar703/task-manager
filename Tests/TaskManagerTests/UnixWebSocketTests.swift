import CodexTransport
import Foundation
import Testing

private let websocketFixture = #"""
import base64, hashlib, json, os, socket, struct, sys
path, mode = sys.argv[1:]
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(1)
c, _ = s.accept(); c.settimeout(10)
def read(n):
    data = b''
    while len(data) < n:
        part = c.recv(n-len(data))
        if not part: raise EOFError()
        data += part
    return data
def receive():
    first, second = read(2)
    assert second & 128, 'client frames must be masked'
    n = second & 127
    if n == 126: n = struct.unpack('!H', read(2))[0]
    if n == 127: n = struct.unpack('!Q', read(8))[0]
    mask = read(4); data = read(n)
    return first & 15, bytes(b ^ mask[i%4] for i,b in enumerate(data))
def send(data, opcode=1, final=True):
    n = len(data); head = bytes([(128 if final else 0) | opcode])
    if n < 126: head += bytes([n])
    elif n < 65536: head += bytes([126]) + struct.pack('!H', n)
    else: head += bytes([127]) + struct.pack('!Q', n)
    c.sendall(head + data)
try:
    headers = b''
    while not headers.endswith(b'\r\n\r\n'): headers += read(1)
    key = next(line.split(b':',1)[1].strip() for line in headers.split(b'\r\n') if line.lower().startswith(b'sec-websocket-key:'))
    accept = base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
    if mode == 'bad-handshake': accept = b'invalid'
    c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
    if mode == 'bad-handshake': sys.exit(0)
    _, body = receive(); req = json.loads(body)
    if mode == 'oversized':
        c.sendall(b'\x81\x7f' + struct.pack('!Q', 4194305)); sys.exit(0)
    if mode == 'masked-server':
        c.sendall(b'\x81\x80'); sys.exit(0)
    result = json.dumps({'id':req['id'], 'result':{'userAgent':'fixture'}}).encode()
    send(b'ping', 9)
    send(result[:10], final=False); send(result[10:], opcode=0)
    while True:
        opcode, body = receive()
        if opcode == 10:
            assert body == b'ping'; continue
        req = json.loads(body)
        if req.get('method') == 'initialized': continue
        assert len(req['params']['payload']) == 70000
        send(json.dumps({'method':'item/agentMessage/delta', 'params':{'delta':'x'*70000}}).encode())
        send(json.dumps({'id':req['id'], 'result':{'ok':True}}).encode())
except (EOFError, BrokenPipeError, ConnectionResetError): pass
finally:
    c.close(); s.close()
"""#

@Test(arguments: ["normal", "oversized", "masked-server", "bad-handshake"])
func unixWebsocketValidatesFramesAndSupportsFragmentation(mode: String) async throws {
    let directory = "/tmp/task-manager-ws-test-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = directory + "/s"
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-c", websocketFixture, path, mode]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: path), server.isRunning, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let client = CodexClient()
    do {
        if mode == "bad-handshake" {
            await #expect(throws: TransportError.self) { try await client.connect(unixSocket: path) }
        } else {
            try await client.connect(unixSocket: path)
            if mode != "normal" { await #expect(throws: TransportError.self) { try await client.initialize() } }
            else {
                _ = try await client.initialize()
                let response = try await client.request("test", params: .object(["payload": .string(String(repeating: "z", count: 70000))]))
                #expect(response["ok"] == .bool(true))
                var events = client.events.makeAsyncIterator()
                #expect(await events.next()?.params["delta"]?.string?.count == 70000)
            }
        }
        await client.stop()
    } catch { await client.stop(); throw error }
}
