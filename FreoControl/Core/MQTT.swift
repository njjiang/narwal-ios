import Foundation

// Original, narrowly scoped MQTT 5 request implementation. Outgoing publications
// use QoS 0 and are never retried. This is not a general-purpose MQTT client.
public enum NarwalMQTT {
    public static func exchange(destination: VerifiedDestination, uuid: String, token: String,
                                device: RobotDevice, topic: String, payload: Data,
                                correlation: Data, isCommand: Bool = false,
                                preflight: (@Sendable () async throws -> Void)? = nil) async throws -> Data {
        guard destination.host == "us-01.mqtt.narwaltech.com", destination.port == 8883 else {
            throw ConnectorError.invalid("The robot destination is not permitted.")
        }
        let session = try MQTTSession(uuid: uuid, token: token, device: device, topic: topic,
                                      payload: payload, correlation: correlation, isCommand: isCommand)
        let mapRequest = topic.hasSuffix("/map/get_map") || topic.hasSuffix("/map/get_editable_map") || topic.hasSuffix("/map/operation")
        let socket = try await PinnedTLSConnection.open(destination: destination, timeout: mapRequest ? 30 : 20)
        return try await run(socket, session: session, isCommand: isCommand, preflight: preflight)
    }

    // Socket abstraction is internal, solely to verify failure/cancellation behavior
    // without opening connections. Production always constructs PinnedTLSConnection.
    static func run(_ socket: any MQTTChannel, session initialSession: MQTTSession, isCommand: Bool,
                    preflight: (@Sendable () async throws -> Void)? = nil) async throws -> Data {
        var session = initialSession
        defer { socket.close() }
        var published = false
        do {
            try await preflight?()
            try Task.checkCancellation()
            try await socket.send(session.connect)
            var decoder = MQTTFrameDecoder()
            while true {
                let chunk = try await socket.read(minimum: 1, maximum: 65536)
                guard !chunk.isEmpty else { throw ConnectorError.invalid("The robot connection ended before its reply.") }
                for frame in try decoder.append(chunk) {
                    let outgoing = try session.receive(frame)
                    for packet in outgoing {
                        if packet.first == 0x30 { try await preflight?() }
                        try Task.checkCancellation()
                        if packet.first == 0x30 { published = true }
                        try await socket.send(packet)
                    }
                    if let response = session.response {
                        // A reply is sufficient; failure of this best-effort DISCONNECT
                        // cannot turn an acknowledged command into an unknown outcome.
                        try? await socket.send(Data([0xe0, 0]))
                        return response
                    }
                }
            }
        } catch {
            if isCommand && published { throw ConnectorError.outcomeUnknown }
            throw error
        }
    }
}

protocol MQTTChannel: Sendable {
    func send(_ data: Data) async throws
    func read(minimum: Int, maximum: Int) async throws -> Data
    func close()
}
extension PinnedTLSConnection: MQTTChannel {}

struct MQTTFrame {
    let header: UInt8
    let body: Data
    var type: Int { Int(header >> 4) }
    var flags: UInt8 { header & 15 }
}

enum MQTTCodec {
    static let maximumPacket = 1_048_576
    static func variable(_ value: Int) throws -> Data {
        guard (0...268_435_455).contains(value) else { throw ConnectorError.invalid("Invalid MQTT length.") }
        var value = value, data = Data()
        repeat {
            var byte = UInt8(value % 128); value /= 128
            if value > 0 { byte |= 128 }
            data.append(byte)
        } while value > 0
        return data
    }
    static func decodeVariable(_ bytes: Data, at offset: Int) throws -> (value: Int, end: Int)? {
        var value = 0, multiplier = 1
        for index in 0..<4 {
            guard offset + index < bytes.count else { return nil }
            let byte = bytes[offset + index]
            value += Int(byte & 127) * multiplier
            if byte & 128 == 0 {
                guard index == 0 || byte != 0 else { throw ConnectorError.invalid("Non-canonical MQTT length.") }
                return (value, offset + index + 1)
            }
            multiplier *= 128
        }
        throw ConnectorError.invalid("Malformed MQTT variable length.")
    }
    static func binary(_ data: Data) throws -> Data {
        guard data.count <= 65535 else { throw ConnectorError.invalid("Oversized MQTT field.") }
        return Data([UInt8(data.count >> 8), UInt8(data.count & 255)]) + data
    }
    static func text(_ value: String) throws -> Data {
        guard !value.unicodeScalars.contains(where: { $0.value == 0 || (0xfdd0...0xfdef).contains($0.value) || $0.value & 0xffff == 0xffff || $0.value & 0xffff == 0xfffe }) else {
            throw ConnectorError.invalid("Invalid MQTT text.")
        }
        return try binary(Data(value.utf8))
    }
    static func packet(_ header: UInt8, _ body: Data = Data()) throws -> Data {
        guard body.count <= maximumPacket - 5 else { throw ConnectorError.invalid("The MQTT packet exceeds 1 MiB.") }
        return try Data([header]) + variable(body.count) + body
    }
    static func connect(username: String, token: String, clientID: String) throws -> Data {
        // Maximum Packet Size = 1 MiB; Request Problem Information = false.
        let properties = Data([0x27, 0, 0x10, 0, 0, 0x17, 0])
        let head = try text("MQTT") + Data([5, 0xc2, 0, 0]) + variable(properties.count) + properties
        return try packet(0x10, head + text(clientID) + text(username) + binary(Data(token.utf8)))
    }
    static func subscribe(topic: String) throws -> Data {
        try packet(0x82, Data([0, 1, 0]) + text(topic) + Data([0]))
    }
    static func publish(topic: String, responseTopic: String, payload: Data, correlation: Data) throws -> Data {
        let properties = try Data([8]) + text(responseTopic) + Data([9]) + binary(correlation)
        return try packet(0x30, text(topic) + variable(properties.count) + properties + payload)
    }
    static func decodePublish(_ frame: MQTTFrame) throws -> MQTTPublication {
        let qos = Int((frame.flags >> 1) & 3)
        guard frame.type == 3, qos <= 1, qos != 0 || frame.flags & 8 == 0 else {
            throw ConnectorError.invalid("Unsupported MQTT publication flags.")
        }
        var reader = MQTTReader(frame.body)
        let topic = try reader.text()
        guard !topic.isEmpty, !topic.contains("+"), !topic.contains("#") else { throw ConnectorError.invalid("Invalid MQTT response topic.") }
        let identifier = qos == 1 ? try reader.u16() : nil
        guard identifier != 0 else { throw ConnectorError.invalid("Invalid MQTT packet identifier.") }
        let correlation = try reader.properties()
        return MQTTPublication(topic: topic, identifier: identifier, correlation: correlation,
                               payload: try reader.take(reader.remaining), retained: frame.flags & 1 != 0)
    }
}

struct MQTTFrameDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [MQTTFrame] {
        guard buffer.count + data.count <= MQTTCodec.maximumPacket * 2 else { throw ConnectorError.invalid("Oversized MQTT input buffer.") }
        buffer.append(data)
        var frames: [MQTTFrame] = []
        while buffer.count >= 2 {
            guard let length = try MQTTCodec.decodeVariable(buffer, at: 1) else { break }
            let total = length.end + length.value
            guard total <= MQTTCodec.maximumPacket else { throw ConnectorError.invalid("The MQTT response exceeds 1 MiB.") }
            guard buffer.count >= total else { break }
            let header = buffer[0], type = Int(header >> 4), flags = header & 15
            let requiredFlags: UInt8 = [6, 8, 10].contains(type) ? 2 : 0
            guard type > 0, type <= 15, type == 3 || flags == requiredFlags, frames.count < 4096 else {
                throw ConnectorError.invalid("Malformed MQTT fixed header.")
            }
            frames.append(MQTTFrame(header: header, body: Data(buffer[length.end..<total])))
            buffer = Data(buffer.dropFirst(total))
        }
        return frames
    }
}

struct MQTTReader {
    private let data: Data
    private var offset = 0
    var remaining: Int { data.count - offset }
    init(_ data: Data) { self.data = data }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw ConnectorError.invalid("Truncated MQTT packet.") }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> UInt16 {
        let bytes = try take(2); return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }
    mutating func variable() throws -> Int {
        guard let result = try MQTTCodec.decodeVariable(data, at: offset) else { throw ConnectorError.invalid("Truncated MQTT variable length.") }
        offset = result.end; return result.value
    }
    mutating func binary() throws -> Data { try take(Int(u16())) }
    mutating func text() throws -> String {
        guard let value = String(data: try binary(), encoding: .utf8), !value.contains("\0") else {
            throw ConnectorError.invalid("Invalid UTF-8 in MQTT response.")
        }
        _ = try MQTTCodec.text(value)
        return value
    }
    /// Parse every property by its wire type, retaining only correlation bytes.
    /// Other server strings never reach errors, logs or the application model.
    mutating func properties() throws -> Data? {
        var reader = try MQTTReader(take(variable()))
        var seen = Set<Int>(), correlation: Data?, count = 0
        while reader.remaining > 0 {
            let id = try reader.variable()
            count += 1
            guard count <= 1024, seen.insert(id).inserted || [11, 38].contains(id) else {
                throw ConnectorError.invalid("Duplicate or excessive MQTT properties.")
            }
            switch id {
            case 1, 23, 25, 36, 37, 40, 41, 42: _ = try reader.byte()
            case 19, 33, 34, 35: _ = try reader.u16()
            case 2, 17, 24, 39: _ = try reader.take(4)
            case 3, 8, 18, 21, 26, 28, 31: _ = try reader.text()
            case 9: correlation = try reader.binary()
            case 22: _ = try reader.binary()
            case 11: _ = try reader.variable()
            case 38: _ = try reader.text(); _ = try reader.text()
            default: throw ConnectorError.invalid("Unsupported MQTT property.")
            }
        }
        return correlation
    }
    func done() throws {
        guard remaining == 0 else { throw ConnectorError.invalid("Unexpected MQTT control payload.") }
    }
}

struct MQTTPublication {
    let topic: String
    let identifier: UInt16?
    let correlation: Data?
    let payload: Data
    let retained: Bool
}

/// The handshake is testable without a socket or credentials. Only a successful
/// subscription creates a publication, and the transition cannot be repeated.
struct MQTTSession {
    private enum Stage { case connect, subscribe, response, done }
    private var stage: Stage = .connect
    private let topic: String
    private let responseTopic: String
    private let payload: Data
    private let correlation: Data
    let connect: Data
    private(set) var response: Data?
    init(uuid: String, token: String, device: RobotDevice, topic: String, payload: Data,
         correlation: Data, isCommand: Bool) throws {
        let uuidValid = uuid.range(of: "^(?:[A-Fa-f0-9]{32}|[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12})$", options: .regularExpression) != nil
        guard uuidValid, !token.isEmpty, token.utf8.count <= 16384,
              device.id.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil,
              device.productKey.range(of: "^[A-Za-z0-9]{1,32}$", options: .regularExpression) != nil,
              payload.count <= 131072, (1...256).contains(correlation.count) else {
            throw ConnectorError.invalid("Invalid MQTT request or authentication fields.")
        }
        let prefix = "/\(device.productKey)/\(device.id)/"
        guard topic.hasPrefix(prefix) else { throw ConnectorError.invalid("The MQTT topic does not match the selected robot.") }
        let suffix = String(topic.dropFirst(prefix.count))
        let reads = ["status/get_device_base_status", "map/get_map", "map/get_editable_map", "clean/current_clean_task/get", "common/get_feature_list"]
        let commands = ["task/pause", "task/resume", "supply/recall", "clean/start_clean", "map/operation"]
        guard (isCommand ? commands : reads).contains(suffix) else { throw ConnectorError.invalid("This MQTT operation is not permitted.") }
        self.topic = topic; responseTopic = topic + "/response"; self.payload = payload; self.correlation = correlation
        connect = try MQTTCodec.connect(username: uuid, token: token, clientID: "app_\(uuid)_\(UUID().uuidString.lowercased())")
    }
    mutating func receive(_ frame: MQTTFrame) throws -> [Data] {
        guard stage != .done else { return [] }
        guard frame.type != 14 else { throw ConnectorError.invalid("The MQTT server ended the connection.") }
        if stage == .connect {
            guard frame.type == 2 else { throw ConnectorError.invalid("Expected MQTT connection acknowledgement.") }
            var reader = MQTTReader(frame.body)
            let flags = try reader.byte(), reason = try reader.byte()
            _ = try reader.properties(); try reader.done()
            guard flags == 0 else { throw ConnectorError.invalid("Unexpected MQTT session state.") }
            guard reason == 0 else { throw ConnectorError.invalid("MQTT authentication or connection rejected (code \(reason)).") }
            stage = .subscribe
            return [try MQTTCodec.subscribe(topic: responseTopic)]
        }
        if frame.type == 9 {
            guard stage == .subscribe else { throw ConnectorError.invalid("Unexpected MQTT subscription acknowledgement.") }
            var reader = MQTTReader(frame.body)
            let id = try reader.u16(); _ = try reader.properties(); let code = try reader.byte(); try reader.done()
            guard id == 1, code == 0 else { throw ConnectorError.invalid("The MQTT response subscription was rejected.") }
            let publication = try MQTTCodec.publish(topic: topic, responseTopic: responseTopic, payload: payload, correlation: correlation)
            stage = .response
            return [publication]
        }
        if frame.type == 3 {
            let message = try MQTTCodec.decodePublish(frame)
            var outgoing: [Data] = []
            if let id = message.identifier {
                outgoing.append(try MQTTCodec.packet(0x40, Data([UInt8(id >> 8), UInt8(id & 255)])))
            }
            // Narwal can omit correlation; a dedicated connection and exact topic
            // remain required. This reply is an acknowledgement, not physical proof.
            if stage == .response, !message.retained, message.topic == responseTopic,
               message.correlation == nil || message.correlation == correlation {
                response = message.payload; stage = .done
            }
            return outgoing
        }
        if frame.type == 13, frame.body.isEmpty { return [] }
        throw ConnectorError.invalid("Unexpected MQTT control packet.")
    }
}
