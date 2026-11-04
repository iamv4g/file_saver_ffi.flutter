import Foundation
import Network

/// A local HTTP server for download tests, on a free port of 127.0.0.1.
///
/// Routes:
/// - `/sized`: `payload` with Content-Length
/// - `/chunked`: `payload` in chunks of 64 KiB, without Content-Length
/// - `/gzip`: `payload` gzip-encoded, with the Content-Length of the encoded body
/// - `/truncated`: the first half of `payload`, with the Content-Length of all of it
/// - anything else: 404
final class TestHTTPServer {
    let payload: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestHTTPServer")

    init(payload: Data) throws {
        self.payload = payload
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    func url(_ path: String) -> String {
        "http://127.0.0.1:\(listener.port!.rawValue)\(path)"
    }

    func close() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    /// Reads up to the end of the request head, then responds.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let requestLine = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).split(separator: " ")
                self.respond(on: connection, path: requestLine.count > 1 ? String(requestLine[1]) : "/")
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, path: String) {
        var status = "200 OK"
        var headers: String
        var body: Data
        switch path {
        case "/sized":
            headers = "Content-Length: \(payload.count)\r\n"
            body = payload
        case "/chunked":
            headers = "Transfer-Encoding: chunked\r\n"
            body = Data()
            var offset = 0
            while offset < payload.count {
                let chunk = payload[offset..<min(offset + 64 * 1024, payload.count)]
                body.append(Data("\(String(chunk.count, radix: 16))\r\n".utf8) + chunk + Data("\r\n".utf8))
                offset += chunk.count
            }
            body.append(Data("0\r\n\r\n".utf8))
        case "/gzip":
            body = Self.gzip(payload)
            headers = "Content-Encoding: gzip\r\nContent-Length: \(body.count)\r\n"
        case "/truncated":
            headers = "Content-Length: \(payload.count)\r\n"
            body = payload.prefix(payload.count / 2)
        default:
            status = "404 Not Found"
            headers = "Content-Length: 0\r\n"
            body = Data()
        }
        let head = Data("HTTP/1.1 \(status)\r\nConnection: close\r\n\(headers)\r\n".utf8)
        connection.send(content: head + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// `data` in the gzip format: a header, the raw deflate stream, its CRC-32
    /// and its size.
    private static func gzip(_ data: Data) -> Data {
        // `.zlib` is raw deflate, without the zlib header.
        let deflated = (try? (data as NSData).compressed(using: .zlib)) as Data? ?? Data()
        var gzip = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
        gzip.append(deflated)
        withUnsafeBytes(of: crc32(data).littleEndian) { gzip.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { gzip.append(contentsOf: $0) }
        return gzip
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
