import Foundation

/// A finite, foreground telemetry lease. This client cannot publish cleaning,
/// map-editing or configuration commands, and never retries a publication.
public enum NarwalLiveMQTT {
    public static func observeWindow(destination: VerifiedDestination, uuid: String, token: String,
                                     device: RobotDevice, baseline: LiveMapSnapshot,
                                     windowSeconds: TimeInterval = 45,
                                     preflight: (@Sendable () async throws -> Void)? = nil,
                                     onEvent: @escaping @Sendable (LiveTelemetryEvent) async throws -> Void) async throws {
        guard destination.host == "us-01.mqtt.narwaltech.com", destination.port == 8883,
              windowSeconds.isFinite, (5...50).contains(windowSeconds),
              baseline.snapshot.productKey == device.productKey, baseline.snapshot.deviceID == device.id else {
            throw ConnectorError.invalid("Invalid live telemetry destination, duration or robot scope.")
        }
        let session = try LiveMQTTSession(uuid: uuid, token: token, device: device, minimumLease: Int(ceil(windowSeconds * 1000)))
        let accumulator = try LiveTelemetryAccumulator(baseline: baseline)
        try await preflight?()
        try Task.checkCancellation()
        let socket = try await PinnedTLSConnection.open(destination: destination, timeout: 60)
        try await run(socket, session: session, accumulator: accumulator, windowSeconds: windowSeconds,
                      preflight: preflight, onEvent: onEvent)
    }

    /// Internal channel seam permits complete handshake/deadline/cancellation
    /// tests without opening any network connection.
    static func run(_ socket: any MQTTChannel, session: LiveMQTTSession,
                    accumulator: LiveTelemetryAccumulator, windowSeconds: TimeInterval,
                    preflight: (@Sendable () async throws -> Void)? = nil,
                    onEvent: @escaping @Sendable (LiveTelemetryEvent) async throws -> Void) async throws {
        guard windowSeconds.isFinite, windowSeconds > 0, windowSeconds <= 50 else {
            socket.close(); throw ConnectorError.invalid("Invalid live telemetry duration.")
        }
        defer { socket.close() }
        let progress = LiveWindowProgress()
        try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await receive(socket, session: session, accumulator: accumulator,
                                      progress: progress, preflight: preflight, onEvent: onEvent)
                    return true // clean stop after requested baseline resynchronization
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(windowSeconds * 1_000_000_000))
                    return false
                }
                defer { group.cancelAll(); socket.close() }
                let resynchronized = try await group.next() ?? false
                try Task.checkCancellation()
                if !resynchronized, !(await progress.wasActivated) {
                    throw ConnectorError.invalid("The robot did not acknowledge live map reporting before the window ended.")
                }
            }
        }, onCancel: { socket.close() })
    }

    private static func receive(_ socket: any MQTTChannel, session initial: LiveMQTTSession,
                                accumulator initialAccumulator: LiveTelemetryAccumulator,
                                progress: LiveWindowProgress,
                                preflight: (@Sendable () async throws -> Void)?,
                                onEvent: @escaping @Sendable (LiveTelemetryEvent) async throws -> Void) async throws {
        try await withTaskCancellationHandler(operation: {
            var session = initial, accumulator = initialAccumulator, decoder = MQTTFrameDecoder()
            try await preflight?()
            try Task.checkCancellation()
            try await socket.send(session.connect)
            var totalBytes = 0, totalPackets = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await socket.read(minimum: 1, maximum: 65536)
                guard !chunk.isEmpty else { throw ConnectorError.invalid("The live robot connection ended.") }
                totalBytes += chunk.count
                guard totalBytes <= 16 * 1_048_576 else { throw ConnectorError.invalid("The live reporting window exceeded its input limit.") }
                for frame in try decoder.append(chunk) {
                    totalPackets += 1
                    guard totalPackets <= 4096 else { throw ConnectorError.invalid("Too many live MQTT packets.") }
                    let result = try session.receive(frame)
                    for packet in result.packets {
                        if packet.first == 0x82 || packet.first == 0x30 { try await preflight?() }
                        try Task.checkCancellation()
                        try await socket.send(packet)
                    }
                    if let event = result.event {
                        try await preflight?()
                        try Task.checkCancellation()
                        await progress.activate()
                        try await onEvent(event)
                    }
                    if let display = result.displayMap {
                        try await preflight?()
                        try Task.checkCancellation()
                        if let event = try accumulator.consume(display, receivedAt: Date()) {
                            try await onEvent(event)
                            if case .resyncRequired = event { return }
                        }
                    }
                }
            }
        }, onCancel: { socket.close() })
    }
}

private actor LiveWindowProgress {
    private(set) var wasActivated = false
    func activate() { wasActivated = true }
}

struct LiveMQTTSession: Sendable {
    private enum Stage: Sendable { case connection, subscription, activation, observing }
    private var stage: Stage = .connection
    let connect: Data
    let topics: [String]
    let activationTopic: String
    let correlation: Data
    private let activationPayload: Data
    private let minimumLease: Int

    init(uuid: String, token: String, device: RobotDevice, minimumLease: Int = 45_000) throws {
        let prefix = "/\(device.productKey)/\(device.id)/"
        // Reuse all existing identity/token/device validation, without adding a
        // new topic to the ordinary command/read allowlist.
        let identity = try NarwalCodec.identity(uuid: uuid)
        _ = try MQTTSession(uuid: uuid, token: token, device: device,
            topic: prefix + "status/get_device_base_status", payload: identity,
            correlation: Data([1]), isCommand: false)
        guard (1...50_000).contains(minimumLease) else { throw ConnectorError.invalid("Invalid telemetry lease requirement.") }
        self.minimumLease = minimumLease
        activationTopic = prefix + "common/active_robot_publish"
        topics = [activationTopic + "/response", prefix + "map/display_map", prefix + "general/topic"]
        activationPayload = try NarwalCodec.liveActivation(uuid: uuid)
        correlation = try NarwalCodec.correlation(id: UUID().uuidString.lowercased(), timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
        connect = try MQTTCodec.connect(username: uuid, token: token,
            clientID: "app_\(uuid)_\(UUID().uuidString.lowercased())")
    }

    mutating func receive(_ frame: MQTTFrame) throws -> (packets: [Data], event: LiveTelemetryEvent?, displayMap: Data?) {
        guard frame.type != 14 else { throw ConnectorError.invalid("The MQTT server ended live reporting.") }
        if stage == .connection {
            guard frame.type == 2 else { throw ConnectorError.invalid("Expected a live MQTT connection acknowledgement.") }
            var reader = MQTTReader(frame.body)
            let flags = try reader.byte(), reason = try reader.byte()
            _ = try reader.properties(); try reader.done()
            guard flags == 0, reason == 0 else { throw ConnectorError.invalid("The live MQTT connection was rejected.") }
            var body = Data([0, 1, 0])
            for topic in topics { body += try MQTTCodec.text(topic) + Data([0]) }
            stage = .subscription
            return ([try MQTTCodec.packet(0x82, body)], nil, nil)
        }
        if frame.type == 9 {
            guard stage == .subscription else { throw ConnectorError.invalid("Unexpected live MQTT subscription acknowledgement.") }
            var reader = MQTTReader(frame.body)
            let identifier = try reader.u16(); _ = try reader.properties()
            guard identifier == 1, reader.remaining == topics.count else { throw ConnectorError.invalid("Invalid live MQTT subscription acknowledgement.") }
            for _ in topics {
                guard try reader.byte() == 0 else { throw ConnectorError.invalid("A live MQTT subscription was rejected.") }
            }
            try reader.done()
            stage = .activation
            return ([try MQTTCodec.publish(topic: activationTopic, responseTopic: topics[0],
                payload: activationPayload, correlation: correlation)], nil, nil)
        }
        if frame.type == 3 {
            let message = try MQTTCodec.decodePublish(frame)
            var packets: [Data] = []
            if let id = message.identifier { packets = [try MQTTCodec.packet(0x40, Data([UInt8(id >> 8), UInt8(id & 255)]))] }
            guard !message.retained else { return (packets, nil, nil) }
            if message.topic == topics[0], stage == .activation,
               message.correlation == nil || message.correlation == correlation {
                let accepted = try NarwalCodec.liveActivationReply(message.payload)
                guard accepted.lease >= minimumLease else { throw ConnectorError.invalid("The robot returned a shorter live reporting lease than requested.") }
                stage = .observing
                return (packets, .activated(leaseMilliseconds: accepted.lease, intervalMilliseconds: accepted.interval), nil)
            }
            guard stage == .observing else { return (packets, nil, nil) }
            if message.topic == topics[1] { return (packets, nil, message.payload) }
            if message.topic == topics[2] { return (packets, nil, try NarwalCodec.generalDisplayMap(message.payload)) }
            return (packets, nil, nil)
        }
        if frame.type == 13, frame.body.isEmpty { return ([], nil, nil) }
        throw ConnectorError.invalid("Unexpected MQTT packet during live reporting.")
    }
}
