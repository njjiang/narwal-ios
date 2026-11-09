import Foundation
import XCTest
@testable import FreoCore

enum LiveFixture {
    static let uuid = String(repeating: "b", count: 32)
    static let device = RobotDevice(id: RouteFixture.deviceID, productKey: "EHf6cRNRGT", name: "Synthetic")
    static func baseline(sequence: UInt64 = 10) throws -> LiveMapSnapshot {
        let snapshot = RouteFixture.snapshot(sequence: sequence, timestamp: 1000)
        return LiveMapSnapshot(snapshot: snapshot, trajectory: try NarwalCodec.trajectory(snapshot: snapshot))
    }
    static func display(firstSequence: UInt64 = 11, sequence: UInt64 = 11, start: UInt64 = 2,
                        points: [(Float, Float)] = [(2, 8), (3, 7)], extra: Data = Data(),
                        timestamp: UInt64 = 2000, includePose: Bool = true) -> Data {
        let point = Data([0x0d]) + RouteFixture.float(3) + Data([0x15]) + RouteFixture.float(7)
        let pose = includePose ? RouteFixture.bytes(1, RouteFixture.bytes(1, point)) : Data()
        return pose + RouteFixture.bytes(2, RouteFixture.path(points)) + RouteFixture.number(3, start) +
            RouteFixture.number(6, 2) + RouteFixture.bytes(7, RouteFixture.number(1, firstSequence) + RouteFixture.number(2, sequence)) +
            RouteFixture.number(10, timestamp) + extra
    }
    static func frame(_ body: Data) -> Data { Data([1]) + RouteFixture.integer(UInt64(body.count)) + body }
    static func activation(lease: UInt64 = 60_000, interval: UInt64 = 2000, error: UInt64 = 0) -> Data {
        frame(RouteFixture.bytes(1, RouteFixture.number(2, interval)) + RouteFixture.number(2, lease) + RouteFixture.number(4, error))
    }
    static func publication(_ topic: String, _ payload: Data, retained: Bool = false, correlation: Data? = nil, qosID: UInt16? = nil) throws -> MQTTFrame {
        var properties = Data()
        if let correlation { properties = try Data([9]) + MQTTCodec.binary(correlation) }
        var body = try MQTTCodec.text(topic)
        if let qosID { body += Data([UInt8(qosID >> 8), UInt8(qosID & 255)]) }
        body += try MQTTCodec.variable(properties.count) + properties + payload
        return MQTTFrame(header: 0x30 | (retained ? 1 : 0) | (qosID == nil ? 0 : 2), body: body)
    }
    static func wire(_ frame: MQTTFrame) throws -> Data { try MQTTCodec.packet(frame.header, frame.body) }
}

final class LiveTelemetryTests: XCTestCase {
    func testSequentialPushAppendsOnlyReceivedPointsAndUsesReceptionTime() throws {
        var accumulator = try LiveTelemetryAccumulator(baseline: LiveFixture.baseline())
        let at = Date(timeIntervalSince1970: 500)
        guard case .trajectory(let value) = try accumulator.consume(LiveFixture.display(), receivedAt: at) else { return XCTFail("Expected observed trajectory") }
        XCTAssertEqual(value.points.count, 4)
        XCTAssertEqual(value.points.last, RobotPathPoint(x: 3.5, y: 3.5))
        XCTAssertEqual(value.pose?.point, RobotPathPoint(x: 3.5, y: 3.5))
        XCTAssertEqual(value.capturedAt, at); XCTAssertEqual(value.deviceTimestampMilliseconds, 2000)
        XCTAssertEqual(value.sequenceID, 11); XCTAssertFalse(value.isSimulated)
        XCTAssertEqual(value.mapID, 1); XCTAssertEqual(value.editVersion, 1)
        XCTAssertEqual(value.segments.first?.typeCode, 4)
    }

    func testDuplicateOutOfOrderAndGeneralTopicFiltering() throws {
        var accumulator = try LiveTelemetryAccumulator(baseline: LiveFixture.baseline())
        XCTAssertNil(try accumulator.consume(LiveFixture.display(firstSequence: 9, sequence: 10)))
        _ = try accumulator.consume(LiveFixture.display())
        XCTAssertNil(try accumulator.consume(LiveFixture.display()))
        let payload = LiveFixture.display()
        XCTAssertEqual(try NarwalCodec.generalDisplayMap(RouteFixture.bytes(1, Data("/map/display_map".utf8)) + RouteFixture.bytes(2, payload)), payload)
        XCTAssertNil(try NarwalCodec.generalDisplayMap(RouteFixture.bytes(1, Data("/status/work_status".utf8)) + RouteFixture.bytes(2, Data([255]))))
        XCTAssertThrowsError(try NarwalCodec.generalDisplayMap(RouteFixture.bytes(1, Data("/map/display_map".utf8))))
    }

    func testGapsPathMismatchNewMapAndBackwardsTimestampRequireResyncWithoutFurtherOutput() throws {
        let fixtures = [
            LiveFixture.display(firstSequence: 12, sequence: 12),
            LiveFixture.display(start: 4),
            LiveFixture.display(points: [(5, 5), (6, 4)]),
            LiveFixture.display(extra: RouteFixture.bytes(8, Data())),
            LiveFixture.display(timestamp: 999)
        ]
        for payload in fixtures {
            var accumulator = try LiveTelemetryAccumulator(baseline: LiveFixture.baseline())
            guard case .resyncRequired = try accumulator.consume(payload) else { return XCTFail("Must refresh baseline") }
            XCTAssertNil(try accumulator.consume(LiveFixture.display()))
        }
        var noSequence = try LiveTelemetryAccumulator(baseline: LiveFixture.baseline(sequence: UInt64.max))
        guard case .resyncRequired = try noSequence.consume(LiveFixture.display()) else { return XCTFail("Unbounded sequence") }
    }

    func testUnknownRouteTypesPreservedAndMissingPoseNeverGetsRefreshedTimestamp() throws {
        var accumulator = try LiveTelemetryAccumulator(baseline: LiveFixture.baseline())
        let info = RouteFixture.bytes(9, RouteFixture.number(1, 991) + RouteFixture.number(2, 2))
        guard case .trajectory(let value) = try accumulator.consume(LiveFixture.display(extra: info, includePose: false)) else { return XCTFail() }
        XCTAssertEqual(value.segments.map(\.typeCode), [4, 991])
        XCTAssertNil(value.pose); XCTAssertNil(value.deviceTimestampMilliseconds)
    }

    func testMalformedDuplicateOversizedAndNonfiniteDataFailClosed() throws {
        let payloads = [
            LiveFixture.display(extra: RouteFixture.number(6, 2)),
            LiveFixture.display(extra: RouteFixture.bytes(2, Data())),
            LiveFixture.display(points: [(2, 8), (.nan, 7)]),
            LiveFixture.display(points: [(2, 8), (300, 7)]),
            LiveFixture.display(extra: RouteFixture.bytes(9, RouteFixture.number(2, 99))),
            Data(repeating: 0, count: 1_048_577), Data([0x80])
        ]
        for payload in payloads {
            var accumulator = try LiveTelemetryAccumulator(baseline: LiveFixture.baseline())
            XCTAssertThrowsError(try accumulator.consume(payload))
        }
    }

    func testCurvedRouteIsExplicitlyUnavailableButRealPoseCanStillBeShown() throws {
        var accumulator = try LiveTelemetryAccumulator(baseline: LiveFixture.baseline())
        guard case .trajectory(let value) = try accumulator.consume(LiveFixture.display(extra: RouteFixture.bytes(15, Data()))) else { return XCTFail() }
        XCTAssertNotNil(value.unavailableReason); XCTAssertNotNil(value.pose)
        XCTAssertTrue(value.points.isEmpty); XCTAssertTrue(value.segments.isEmpty)
    }

    func testActivationWireContainsOnlyFiniteMapLeaseAndUsesDistinctReplySchema() throws {
        let bytes = try NarwalCodec.liveActivation(uuid: LiveFixture.uuid)
        let body = try NarwalCodec.fields(NarwalCodec.unwrap(bytes))
        XCTAssertEqual(body.map(\.tag), [1, 2, 3])
        XCTAssertEqual(try NarwalCodec.scalar(NarwalCodec.one(body, 2)), 60_000)
        XCTAssertEqual(try NarwalCodec.scalar(NarwalCodec.one(body, 3)), 0)
        let durations = try NarwalCodec.fields(NarwalCodec.message(NarwalCodec.one(body, 1), required: true)!)
        XCTAssertEqual(durations.map(\.tag), [2]); XCTAssertEqual(try NarwalCodec.scalar(durations.first), 2000)
        let accepted = try NarwalCodec.liveActivationReply(LiveFixture.activation())
        XCTAssertEqual(accepted.lease, 60_000); XCTAssertEqual(accepted.interval, 2000)
        XCTAssertThrowsError(try NarwalCodec.liveActivationReply(LiveFixture.activation(error: 1)))
        XCTAssertThrowsError(try NarwalCodec.liveActivationReply(LiveFixture.activation(lease: 60_001)))
        XCTAssertThrowsError(try NarwalCodec.liveActivationReply(LiveFixture.frame(RouteFixture.number(1, 1))))
    }

    func testHandshakeRequiresEverySubscriptionAndPublishesActivationExactlyOnce() throws {
        var session = try LiveMQTTSession(uuid: LiveFixture.uuid, token: "synthetic", device: LiveFixture.device)
        let subscribe = try session.receive(MQTTFrame(header: 0x20, body: Data([0, 0, 0]))).packets
        XCTAssertEqual(subscribe.count, 1); XCTAssertEqual(subscribe.first?.first, 0x82)
        XCTAssertEqual(session.topics.count, 3); XCTAssertFalse(session.topics.contains { $0.contains("#") || $0.contains("+") })
        let outgoing = try session.receive(MQTTFrame(header: 0x90, body: Data([0, 1, 0, 0, 0, 0]))).packets
        XCTAssertEqual(outgoing.count, 1)
        let sent = try MQTTFrameDecoder().decodeOne(outgoing[0])
        let publication = try MQTTCodec.decodePublish(sent)
        XCTAssertTrue(publication.topic.hasSuffix("/common/active_robot_publish"))
        XCTAssertThrowsError(try session.receive(MQTTFrame(header: 0x90, body: Data([0, 1, 0, 0, 0, 0]))))
        let retained = try LiveFixture.publication(session.topics[0], LiveFixture.activation(), retained: true)
        XCTAssertNil(try session.receive(retained).event)
        let wrongCorrelation = try LiveFixture.publication(session.topics[0], LiveFixture.activation(), correlation: Data([9]))
        XCTAssertNil(try session.receive(wrongCorrelation).event)
        let accepted = try session.receive(LiveFixture.publication(session.topics[0], LiveFixture.activation()))
        guard case .activated = accepted.event else { return XCTFail() }
        XCTAssertNil(try session.receive(LiveFixture.publication("/other/device/map/display_map", LiveFixture.display())).displayMap)
        let push = try session.receive(LiveFixture.publication(session.topics[1], LiveFixture.display(), qosID: 7))
        XCTAssertEqual(push.displayMap, LiveFixture.display()); XCTAssertEqual(push.packets, [Data([0x40, 2, 0, 7])])
        XCTAssertNil(try session.receive(LiveFixture.publication(session.topics[1], LiveFixture.display(), retained: true)).displayMap)
    }

    func testRejectedConnectionAndOneRejectedSubscriptionCannotPublish() throws {
        var session = try LiveMQTTSession(uuid: LiveFixture.uuid, token: "synthetic", device: LiveFixture.device)
        XCTAssertThrowsError(try session.receive(MQTTFrame(header: 0x20, body: Data([0, 0x87, 0]))))
        session = try LiveMQTTSession(uuid: LiveFixture.uuid, token: "synthetic", device: LiveFixture.device)
        _ = try session.receive(MQTTFrame(header: 0x20, body: Data([0, 0, 0])))
        XCTAssertThrowsError(try session.receive(MQTTFrame(header: 0x90, body: Data([0, 1, 0, 0, 0x80, 0]))))
    }
}

private extension MQTTFrameDecoder {
    func decodeOne(_ data: Data) throws -> MQTTFrame {
        var decoder = self
        let frames = try decoder.append(data)
        XCTAssertEqual(frames.count, 1)
        return frames[0]
    }
}

private final class LiveTestChannel: MQTTChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [Data]
    private var waiter: CheckedContinuation<Data, Error>?
    private var closed = false
    private var writes: [Data] = []
    init(_ incoming: [Data]) { self.incoming = incoming }
    func send(_ data: Data) async throws { try lock.withLock {
        guard !closed else { throw CancellationError() }; writes.append(data)
    } }
    func read(minimum: Int, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            if !incoming.isEmpty { let data = incoming.removeFirst(); lock.unlock(); continuation.resume(returning: data); return }
            waiter = continuation; lock.unlock()
        }
    }
    func close() {
        let waiter = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            closed = true; defer { self.waiter = nil }; return self.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }
    var isClosed: Bool { lock.withLock { closed } }
    var sent: [Data] { lock.withLock { writes } }
}

private actor LiveTestGuard {
    var calls = 0
    func check() throws { calls += 1; if calls == 3 { throw ConnectorError.invalid("Synthetic policy expiration") } }
}

final class LiveWindowTests: XCTestCase {
    func testFragmentedGeneralPushResyncEndsWindowWithoutAnotherPublication() async throws {
        let session = try LiveMQTTSession(uuid: LiveFixture.uuid, token: "synthetic", device: LiveFixture.device)
        let acknowledgement = try LiveFixture.wire(LiveFixture.publication(session.topics[0], LiveFixture.activation()))
        let general = RouteFixture.bytes(1, Data("/map/display_map".utf8)) +
            RouteFixture.bytes(2, LiveFixture.display(firstSequence: 15, sequence: 15))
        let push = try LiveFixture.wire(LiveFixture.publication(session.topics[2], general, qosID: 12))
        let channel = LiveTestChannel([Data([0x20]), Data([3, 0, 0, 0]), Data([0x90, 6, 0, 1, 0, 0, 0, 0]),
            Data(acknowledgement.prefix(3)), Data(acknowledgement.dropFirst(3)) + Data(push.prefix(8)), Data(push.dropFirst(8))])
        let refreshed = expectation(description: "Fresh baseline requested")
        try await NarwalLiveMQTT.run(channel, session: session, accumulator: LiveTelemetryAccumulator(baseline: LiveFixture.baseline()),
            windowSeconds: 1, onEvent: { event in
                if case .resyncRequired = event { refreshed.fulfill() }
            })
        await fulfillment(of: [refreshed], timeout: 0.1)
        XCTAssertTrue(channel.isClosed)
        XCTAssertEqual(channel.sent.filter { $0.first == 0x30 }.count, 1)
        XCTAssertTrue(channel.sent.contains(Data([0x40, 2, 0, 12])))
    }

    func testCancellationOfActiveStreamClosesPendingReadImmediately() async throws {
        let session = try LiveMQTTSession(uuid: LiveFixture.uuid, token: "synthetic", device: LiveFixture.device)
        let acknowledgement = try LiveFixture.wire(LiveFixture.publication(session.topics[0], LiveFixture.activation()))
        let channel = LiveTestChannel([Data([0x20, 3, 0, 0, 0]), Data([0x90, 6, 0, 1, 0, 0, 0, 0]), acknowledgement])
        let activated = expectation(description: "Reporting activated")
        let accumulator = try LiveTelemetryAccumulator(baseline: LiveFixture.baseline())
        let task = Task {
            try await NarwalLiveMQTT.run(channel, session: session, accumulator: accumulator,
                windowSeconds: 10, onEvent: { event in
                    if case .activated = event { activated.fulfill() }
                })
        }
        await fulfillment(of: [activated], timeout: 1)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertTrue(channel.isClosed)
        XCTAssertEqual(channel.sent.filter { $0.first == 0x30 }.count, 1)
    }

    func testWindowEndsNormallyAfterActivationAndClosesPendingRead() async throws {
        let session = try LiveMQTTSession(uuid: LiveFixture.uuid, token: "synthetic", device: LiveFixture.device)
        let acknowledgement = try LiveFixture.wire(LiveFixture.publication(session.topics[0], LiveFixture.activation()))
        let channel = LiveTestChannel([Data([0x20, 3, 0, 0, 0]), Data([0x90, 6, 0, 1, 0, 0, 0, 0]), acknowledgement])
        try await NarwalLiveMQTT.run(channel, session: session, accumulator: LiveTelemetryAccumulator(baseline: LiveFixture.baseline()),
            windowSeconds: 0.05, onEvent: { _ in })
        XCTAssertTrue(channel.isClosed)
        XCTAssertEqual(channel.sent.filter { $0.first == 0x30 }.count, 1)
    }

    func testPreflightIsRecheckedAfterSubackAndCanBlockActivation() async throws {
        let session = try LiveMQTTSession(uuid: LiveFixture.uuid, token: "synthetic", device: LiveFixture.device)
        let channel = LiveTestChannel([Data([0x20, 3, 0, 0, 0]), Data([0x90, 6, 0, 1, 0, 0, 0, 0])])
        let gate = LiveTestGuard()
        do {
            try await NarwalLiveMQTT.run(channel, session: session, accumulator: LiveTelemetryAccumulator(baseline: LiveFixture.baseline()),
                windowSeconds: 1, preflight: { try await gate.check() }, onEvent: { _ in })
            XCTFail("Expected expired policy")
        } catch { XCTAssertFalse(channel.sent.contains { $0.first == 0x30 }) }
        XCTAssertTrue(channel.isClosed)
    }

    func testCancellationClosesSocketAndDoesNotRetryOrPublish() async throws {
        let session = try LiveMQTTSession(uuid: LiveFixture.uuid, token: "synthetic", device: LiveFixture.device)
        let channel = LiveTestChannel([])
        let baseline = try LiveFixture.baseline()
        let task = Task {
            try await NarwalLiveMQTT.run(channel, session: session, accumulator: LiveTelemetryAccumulator(baseline: baseline),
                windowSeconds: 1, onEvent: { _ in })
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled stream must fail") } catch { }
        XCTAssertTrue(channel.isClosed); XCTAssertFalse(channel.sent.contains { $0.first == 0x30 })
    }

    func testNoActivationAcknowledgementIsNotReportedAsSuccessfulWindow() async throws {
        let session = try LiveMQTTSession(uuid: LiveFixture.uuid, token: "synthetic", device: LiveFixture.device)
        let channel = LiveTestChannel([])
        do {
            try await NarwalLiveMQTT.run(channel, session: session, accumulator: LiveTelemetryAccumulator(baseline: LiveFixture.baseline()),
                windowSeconds: 0.02, onEvent: { _ in })
            XCTFail("Missing acknowledgement")
        } catch { }
        XCTAssertTrue(channel.isClosed)
    }
}
