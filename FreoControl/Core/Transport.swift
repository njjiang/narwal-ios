import Foundation
import Network
import Security

/// An address checked by the network policy before credentials are released.
public struct VerifiedDestination: Sendable {
    public let host: String
    public let port: UInt16
    public let address: String
    public init(host: String, port: UInt16, address: String) {
        self.host = host; self.port = port; self.address = address
    }
    func validate() throws {
        let permitted = (host == "us-app.narwaltech.com" && port == 443)
            || (host == "us-01.mqtt.narwaltech.com" && port == 8883)
        guard permitted, let ip = IPv4Address(address), ip.debugDescription == address,
              USNetworkPolicy.isPublicIPv4(address) else {
            throw ConnectorError.invalid("The destination is not an approved IPv4 endpoint.")
        }
    }
}

/// One-shot completion shared by callback, cancellation and timeout paths.
private final class TransportCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    @discardableResult func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return false }
        self.continuation = continuation
        lock.unlock()
        return true
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// A direct IPv4 TCP connection. TLS still verifies the original hostname.
/// No resolver, URL loading session, trust override, redirect or retry is used.
public final class PinnedTLSConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "FreoControl.pinnedTLS")
    private let deadline: TimeInterval
    private let lock = NSLock()
    private var closed = false
    private var pending: [UUID: () -> Void] = [:]
    private init(connection: NWConnection, timeout: TimeInterval) {
        self.connection = connection
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }

    public static func open(destination: VerifiedDestination, timeout: TimeInterval = 15) async throws -> PinnedTLSConnection {
        try destination.validate()
        guard timeout.isFinite, timeout > 0, timeout <= 60,
              let address = IPv4Address(destination.address), let port = NWEndpoint.Port(rawValue: destination.port) else {
            throw ConnectorError.invalid("Invalid connection deadline or address.")
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, destination.host)
        let verificationQueue = DispatchQueue(label: "FreoControl.certificate")
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let systemTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let policy = SecPolicyCreateSSL(true, destination.host as CFString)
            guard SecTrustSetPolicies(systemTrust, policy) == errSecSuccess else { complete(false); return }
            // Certificate evaluation must not make a second, unpinned request
            // for an intermediate certificate or revocation URL.
            guard SecTrustSetNetworkFetchAllowed(systemTrust, false) == errSecSuccess else { complete(false); return }
            complete(SecTrustEvaluateWithError(systemTrust, nil))
        }, verificationQueue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(ceil(timeout))
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        parameters.includePeerToPeer = false
        let connection = NWConnection(host: .ipv4(address), port: port, using: parameters)
        let socket = PinnedTLSConnection(connection: connection, timeout: timeout)
        do {
            let _: Void = try await socket.operation { complete in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.requestEstablishmentReport(queue: socket.queue) { report in
                            guard let report, !report.usedProxy,
                                  case .hostPort(let remoteHost, let remotePort) = connection.currentPath?.remoteEndpoint,
                                  case .ipv4(let remoteAddress) = remoteHost,
                                  remoteAddress == address, remotePort == port else {
                                complete(.failure(ConnectorError.invalid("The connection did not use the verified direct address.")))
                                return
                            }
                            complete(.success(()))
                        }
                    case .failed, .cancelled:
                        complete(.failure(ConnectorError.invalid("The secure connection could not be established.")))
                    default: break
                    }
                }
                connection.start(queue: socket.queue)
            }
            connection.stateUpdateHandler = nil
            return socket
        } catch { socket.close(); throw error }
    }

    /// A connection's single deadline covers handshake, writes and reads together.
    private func operation<Value>(_ action: @escaping (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let gate = TransportCompletion<Value>()
        let id = UUID()
        let timer = DispatchWorkItem { [weak self] in
            gate.finish(.failure(ConnectorError.invalid("The secure connection timed out.")))
            self?.close()
        }
        let cancel = { gate.finish(.failure(CancellationError())) }
        let available = lock.withLock {
            guard !closed else { return false }
            pending[id] = cancel
            return true
        }
        guard available else { throw ConnectorError.invalid("The secure connection is closed.") }
        defer {
            timer.cancel()
            _ = lock.withLock { pending.removeValue(forKey: id) }
        }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { close(); throw ConnectorError.invalid("The secure connection timed out.") }
            queue.asyncAfter(deadline: .now() + remaining, execute: timer)
            return try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                guard !Task.isCancelled else { gate.finish(.failure(CancellationError())); return }
                action { gate.finish($0) }
            }
        }, onCancel: { gate.finish(.failure(CancellationError())); self.close() })
    }

    public func send(_ data: Data) async throws {
        guard data.count <= 1_114_112 else { throw ConnectorError.invalid("The request exceeds the connection limit.") }
        let _: Void = try await operation { complete in
            self.connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { complete(.failure(ConnectorError.invalid("The secure write failed."))) }
                else { complete(.success(())) }
            })
        }
    }

    /// Empty data means a clean TLS stream EOF. Errors are never treated as EOF.
    public func read(minimum: Int = 1, maximum: Int = 65536) async throws -> Data {
        guard minimum > 0, maximum >= minimum, maximum <= 1_048_576 else {
            throw ConnectorError.invalid("Invalid secure read size.")
        }
        return try await operation { complete in
            self.connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, ended, error in
                if error != nil { complete(.failure(ConnectorError.invalid("The secure response was interrupted."))) }
                else if let data, !data.isEmpty { complete(.success(data)) }
                else if ended { complete(.success(Data())) }
                else { complete(.failure(ConnectorError.invalid("The secure stream returned no data."))) }
            }
        }
    }

    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let cancellations = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        connection.cancel()
        cancellations.forEach { $0() }
    }
    deinit { connection.cancel() }
}

public enum PinnedHTTP {
    public static func request(destination: VerifiedDestination, method: String, path: String,
                               headers: [String: String] = [:], body: Data? = nil,
                               preflight: (@Sendable () async throws -> Void)? = nil) async throws -> Data {
        guard destination.host == "us-app.narwaltech.com", destination.port == 443 else {
            throw ConnectorError.invalid("The account destination is not permitted.")
        }
        let request = try encodeRequest(host: destination.host, method: method, path: path, headers: headers, body: body)
        let socket = try await PinnedTLSConnection.open(destination: destination)
        defer { socket.close() }
        try await preflight?()
        try Task.checkCancellation()
        try await socket.send(request)
        var response = HTTPResponseParser()
        while true {
            let data = try await socket.read()
            if let body = try response.append(data, end: data.isEmpty) { return body }
        }
    }

    static func encodeRequest(host: String, method: String, path: String, headers: [String: String], body: Data?) throws -> Data {
        guard ["GET", "POST"].contains(method), path.hasPrefix("/"), !path.hasPrefix("//"),
              path.utf8.count <= 2048, path.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              !path.contains("#"), (body?.count ?? 0) <= 1_048_576 else {
            throw ConnectorError.invalid("Invalid account request.")
        }
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host)", "Connection: close", "Accept-Encoding: identity"]
        var seen = Set<String>()
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let key = name.lowercased()
            guard HTTPResponseParser.validName(name), seen.insert(key).inserted,
                  !["host", "connection", "content-length", "transfer-encoding", "accept-encoding", "proxy-authorization"].contains(key),
                  value.utf8.count <= 16384, value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 <= 126) }) else {
                throw ConnectorError.invalid("Invalid account request headers.")
            }
            lines.append("\(name): \(value)")
        }
        if method == "POST" || body != nil { lines.append("Content-Length: \(body?.count ?? 0)") }
        let head = lines.joined(separator: "\r\n") + "\r\n\r\n"
        guard head.utf8.count <= 32768 else { throw ConnectorError.invalid("Account headers exceed the limit.") }
        return Data(head.utf8) + (body ?? Data())
    }
}

/// Strict HTTP/1.1 response framing. It never follows redirects or decodes compression.
struct HTTPResponseParser {
    private enum Framing { case length(Int), chunked, close }
    private enum Chunk { case size, content(Int), trailers }
    private var buffer = Data()
    private var body = Data()
    private var framing: Framing?
    private var chunk: Chunk = .size
    private var complete = false
    private var overhead = 0
    private var chunkCount = 0
    private let limit = 1_048_576
    private let crlf = Data([13, 10])

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
        }
    }
    private mutating func consume(_ count: Int) -> Data {
        let value = Data(buffer.prefix(count)); buffer = Data(buffer.dropFirst(count)); return value
    }
    private mutating func addBody(_ data: Data) throws {
        guard body.count + data.count <= limit else { throw ConnectorError.invalid("The account response exceeds 1 MiB.") }
        body.append(data)
    }
    private static func header(_ data: Data) throws -> (String, String) {
        guard let line = String(data: data, encoding: .ascii), let colon = line.firstIndex(of: ":") else {
            throw ConnectorError.invalid("Malformed account response headers.")
        }
        let name = String(line[..<colon]), value = String(line[line.index(after: colon)...])
        guard validName(name), value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 <= 126) }) else {
            throw ConnectorError.invalid("Malformed account response headers.")
        }
        return (name.lowercased(), value.trimmingCharacters(in: .whitespaces))
    }

    mutating func append(_ data: Data, end: Bool = false) throws -> Data? {
        guard !complete, buffer.count + data.count + body.count <= limit + 65536 else {
            throw ConnectorError.invalid("The account response exceeds its framing limit.")
        }
        buffer.append(data)
        if framing == nil {
            guard let boundary = buffer.range(of: Data([13, 10, 13, 10])) else {
                guard !end, buffer.count <= 32768 else { throw ConnectorError.invalid("Incomplete or oversized HTTP headers.") }
                return nil
            }
            guard boundary.upperBound <= 32768 else { throw ConnectorError.invalid("Oversized HTTP headers.") }
            let head = consume(boundary.upperBound)
            guard let text = String(data: head.dropLast(4), encoding: .ascii) else {
                throw ConnectorError.invalid("Invalid HTTP response encoding.")
            }
            let lines = text.components(separatedBy: "\r\n")
            let status = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard status.count >= 2, status[0] == "HTTP/1.1" || status[0] == "HTTP/1.0",
                  status[1].count == 3, let code = Int(status[1]) else { throw ConnectorError.invalid("Malformed HTTP status.") }
            guard code == 200 else { throw AccountHTTPError(status: code) }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let (name, value) = try Self.header(Data(line.utf8))
                if ["content-length", "transfer-encoding", "content-encoding"].contains(name), headers[name] != nil {
                    throw ConnectorError.invalid("Ambiguous HTTP response framing.")
                }
                headers[name] = value
            }
            guard headers["content-encoding"] == nil || headers["content-encoding"]?.lowercased() == "identity" else {
                throw ConnectorError.invalid("Compressed account responses are not supported.")
            }
            if let transfer = headers["transfer-encoding"] {
                guard transfer.lowercased() == "chunked", headers["content-length"] == nil else {
                    throw ConnectorError.invalid("Unsupported or ambiguous HTTP transfer encoding.")
                }
                framing = .chunked
            } else if let length = headers["content-length"] {
                guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
                      let count = Int(length), count <= limit else { throw ConnectorError.invalid("Invalid HTTP response length.") }
                framing = .length(count)
            } else { framing = .close }
        }
        switch framing! {
        case .length(let length):
            guard body.count + buffer.count <= length else { throw ConnectorError.invalid("Unexpected bytes after the HTTP response.") }
            try addBody(consume(buffer.count))
            if body.count == length { complete = true; return body }
        case .close:
            try addBody(consume(buffer.count))
            if end { complete = true; return body }
        case .chunked:
            while true {
                switch chunk {
                case .size:
                    guard let lineEnd = buffer.range(of: crlf) else {
                        guard buffer.count <= 1024 else { throw ConnectorError.invalid("Oversized HTTP chunk header.") }
                        if end { throw ConnectorError.invalid("Truncated HTTP chunk header.") }; return nil
                    }
                    guard lineEnd.lowerBound <= 1024 else { throw ConnectorError.invalid("Oversized HTTP chunk header.") }
                    let line = consume(lineEnd.upperBound).dropLast(2)
                    overhead += line.count + 2; chunkCount += 1
                    guard overhead <= 65536, chunkCount <= 4096,
                          line.allSatisfy({ $0 >= 32 && $0 <= 126 }),
                          let text = String(data: line, encoding: .ascii) else { throw ConnectorError.invalid("Invalid HTTP chunk framing.") }
                    let size = text.split(separator: ";", omittingEmptySubsequences: false)[0]
                    guard !size.isEmpty, size.count <= 8, size.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                          let count = Int(size, radix: 16), count <= limit - body.count else { throw ConnectorError.invalid("Invalid HTTP chunk length.") }
                    chunk = count == 0 ? .trailers : .content(count)
                case .content(let count):
                    guard buffer.count >= count + 2 else {
                        if end { throw ConnectorError.invalid("Truncated HTTP chunk.") }; return nil
                    }
                    try addBody(consume(count))
                    guard consume(2) == crlf else { throw ConnectorError.invalid("Malformed HTTP chunk delimiter.") }
                    overhead += 2; chunk = .size
                case .trailers:
                    guard let lineEnd = buffer.range(of: crlf) else {
                        guard buffer.count <= 32768, !end else { throw ConnectorError.invalid("Truncated or oversized HTTP trailers.") }
                        return nil
                    }
                    let line = consume(lineEnd.upperBound).dropLast(2)
                    overhead += line.count + 2
                    guard overhead <= 65536 else { throw ConnectorError.invalid("Oversized HTTP trailers.") }
                    if line.isEmpty {
                        guard buffer.isEmpty else { throw ConnectorError.invalid("Unexpected bytes after the HTTP response.") }
                        complete = true; return body
                    }
                    let (name, _) = try Self.header(Data(line))
                    guard !["content-length", "transfer-encoding", "content-encoding"].contains(name) else {
                        throw ConnectorError.invalid("Invalid HTTP framing trailer.")
                    }
                }
            }
        }
        if end { throw ConnectorError.invalid("The HTTP response ended before its declared length.") }
        return nil
    }
}
