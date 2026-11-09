import Foundation
import Darwin

public enum NarwalServiceKind: Sendable { case https, mqtt }

/// The policy contains public destination addresses only, never credentials.
public actor USNetworkPolicy {
    private var https: [String] = []
    private var mqtt: [String] = []
    private var expires = Date.distantPast
    public init() {}
    public func expiration() -> Date { expires }
    public func destination(_ kind: NarwalServiceKind) async throws -> VerifiedDestination {
        if Date() >= expires { _ = try await recheck() }
        switch kind {
        case .https: return VerifiedDestination(host: "us-app.narwaltech.com", port: 443, address: https[0])
        case .mqtt: return VerifiedDestination(host: "us-01.mqtt.narwaltech.com", port: 8883, address: mqtt[0])
        }
    }
    public func recheck() async throws -> Date {
        let hosts = ["us-app.narwaltech.com", "us-01.mqtt.narwaltech.com"]
        var addresses: [[String]] = []
        // Resolve the fixed US service names before contacting Narwal.
        // TLS verifies those hostnames in the transport.
        for host in hosts {
            let found = try await Self.resolveIPv4(host)
            guard !found.isEmpty, found.count <= 8, found.allSatisfy(Self.isPublicIPv4) else {
                throw ConnectorError.invalid("DNS did not return a bounded set of public IPv4 addresses. The existing policy was not changed.")
            }
            addresses.append(found)
        }
        try Task.checkCancellation()
        https = addresses[0]; mqtt = addresses[1]; expires = Date().addingTimeInterval(24 * 3600)
        return expires
    }
    public nonisolated static func isPublicIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [UInt32] = []
        for part in parts {
            guard let byte = UInt32(part), byte <= 255, String(byte) == part else { return false }
            octets.append(byte)
        }
        let ip = octets.reduce(UInt32(0)) { ($0 << 8) | $1 }
        let blocked: [(UInt32, Int)] = [(0x00000000,8),(0x0a000000,8),(0x64400000,10),(0x7f000000,8),(0xa9fe0000,16),(0xac100000,12),(0xc0000000,24),(0xc0000200,24),(0xc0586300,24),(0xc0a80000,16),(0xc6120000,15),(0xc6336400,24),(0xcb007100,24),(0xe0000000,4),(0xf0000000,4)]
        return !blocked.contains { network, bits in let mask = UInt32.max << (32 - bits); return ip & mask == network & mask }
    }
    private nonisolated static func resolveIPv4(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let result = DNSResult(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { result.finish(.failure(ConnectorError.invalid("DNS lookup timed out."))) }
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &list) == 0 else { result.finish(.failure(ConnectorError.invalid("Could not resolve the Narwal US service."))); return }
                defer { if let list { freeaddrinfo(list) } }
                var addresses = Set<String>(); var cursor = list
                while let entry = cursor {
                    defer { cursor = entry.pointee.ai_next }
                    guard entry.pointee.ai_family == AF_INET, let address = entry.pointee.ai_addr else { continue }
                    var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil { addresses.insert(String(cString: buffer)) }
                    if addresses.count > 8 { break }
                }
                result.finish(.success(addresses.sorted()))
            }
        }
    }

}

private final class DNSResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Error>?
    init(_ continuation: CheckedContinuation<[String], Error>) { self.continuation = continuation }
    func finish(_ result: Result<[String], Error>) {
        lock.lock(); let saved = continuation; continuation = nil; lock.unlock()
        saved?.resume(with: result)
    }
}
