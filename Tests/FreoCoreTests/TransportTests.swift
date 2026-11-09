import Foundation
import XCTest
@testable import FreoCore

final class TransportTests: XCTestCase {
    func testHTTPContentLengthAcrossEveryByteBoundary() throws {
        let source = Data("HTTP/1.1 200 OK\r\nContent-Length: 7\r\nContent-Type: application/json\r\n\r\n{\"a\":1}".utf8)
        for cut in 1..<source.count {
            var parser = HTTPResponseParser()
            XCTAssertNil(try parser.append(Data(source.prefix(cut))))
            XCTAssertEqual(try parser.append(Data(source.dropFirst(cut))), Data("{\"a\":1}".utf8))
        }
    }

    func testHTTPChunkedMultibyteResponseAndTrailers() throws {
        let source = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;extension=yes\r\nabc\r\n4\r\ndefg\r\n0\r\nX-Trace: ignored\r\n\r\n".utf8)
        var parser = HTTPResponseParser()
        for byte in source.dropLast() { XCTAssertNil(try parser.append(Data([byte]))) }
        XCTAssertEqual(try parser.append(Data([source.last!])), Data("abcdefg".utf8))
    }

    func testHTTPCloseFramingRequiresEOFAndTruncationFails() throws {
        var close = HTTPResponseParser()
        XCTAssertNil(try close.append(Data("HTTP/1.0 200 OK\r\n\r\nhello".utf8)))
        XCTAssertEqual(try close.append(Data(), end: true), Data("hello".utf8))
        var truncated = HTTPResponseParser()
        XCTAssertNil(try truncated.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nabc".utf8)))
        XCTAssertThrowsError(try truncated.append(Data(), end: true))
    }

    func testHTTPRejectsRedirectsAmbiguityCompressionAndInjection() throws {
        let invalid = [
            "HTTP/1.1 302 Found\r\nLocation: https://elsewhere.invalid\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: +1\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nxx",
            "HTTP/1.1 200 OK\r\n Bad: folded\r\n\r\n"
        ]
        for value in invalid {
            var parser = HTTPResponseParser()
            XCTAssertThrowsError(try parser.append(Data(value.utf8)))
        }
        XCTAssertThrowsError(try PinnedHTTP.encodeRequest(host: "us-app.narwaltech.com", method: "POST", path: "/login\r\nX: y", headers: [:], body: nil))
        XCTAssertThrowsError(try PinnedHTTP.encodeRequest(host: "us-app.narwaltech.com", method: "GET", path: "/x", headers: ["Auth-Token": "x\r\nInjected: y"], body: nil))
        XCTAssertThrowsError(try PinnedHTTP.encodeRequest(host: "us-app.narwaltech.com", method: "GET", path: "/x", headers: ["Content-Length": "1"], body: nil))
    }

    func testHTTPChunkFailuresAndSizeBounds() throws {
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        for suffix in ["z\r\n", "100001\r\n", "1\r\nx!!", "0\r\nContent-Length: 2\r\n\r\n", "0\r\n\r\nextra"] {
            var parser = HTTPResponseParser()
            XCTAssertThrowsError(try parser.append(Data((head + suffix).utf8)))
        }
        var incomplete = HTTPResponseParser()
        XCTAssertNil(try incomplete.append(Data((head + "3\r\nab").utf8)))
        XCTAssertThrowsError(try incomplete.append(Data(), end: true))
        var huge = HTTPResponseParser()
        XCTAssertThrowsError(try huge.append(Data(repeating: 65, count: 32769)))
    }

    func testHTTPRequestFramesExactlyOneBody() throws {
        let body = Data([123, 125])
        let request = try PinnedHTTP.encodeRequest(host: "us-app.narwaltech.com", method: "POST", path: "/login", headers: ["Content-Type": "application/json"], body: body)
        let text = String(decoding: request, as: UTF8.self)
        XCTAssertTrue(text.contains("Host: us-app.narwaltech.com\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("Content-Length: 2\r\n\r\n{}"))
    }

    func testDestinationRejectsOtherHostsPortsAndIPv6BeforeConnecting() throws {
        try VerifiedDestination(host: "us-app.narwaltech.com", port: 443, address: "8.8.8.8").validate()
        for target in [
            VerifiedDestination(host: "cn-app.narwaltech.com", port: 443, address: "8.8.8.8"),
            VerifiedDestination(host: "us-app.narwaltech.com", port: 80, address: "8.8.8.8"),
            VerifiedDestination(host: "us-app.narwaltech.com", port: 443, address: "::1"),
            VerifiedDestination(host: "us-app.narwaltech.com", port: 443, address: "127.0.0.1"),
            VerifiedDestination(host: "us-app.narwaltech.com", port: 443, address: "10.0.0.1"),
            VerifiedDestination(host: "us-app.narwaltech.com", port: 443, address: "example.com")
        ] { XCTAssertThrowsError(try target.validate()) }
    }

    private let uuid = "00112233445566778899aabbccddeeff"
    private let device = RobotDevice(id: "ffeeddccbbaa99887766554433221100", productKey: "EHf6cRNRGT", name: "Test")
    private let correlation = Data([1, 2, 3])
    private func topic(_ suffix: String = "status/get_device_base_status") -> String {
        "/\(device.productKey)/\(device.id)/\(suffix)"
    }
    private func session(command: Bool = false, suffix: String? = nil) throws -> MQTTSession {
        try MQTTSession(uuid: uuid, token: "offline-test-token", device: device,
                        topic: topic(suffix ?? (command ? "task/pause" : "status/get_device_base_status")),
                        payload: Data([1, 2]), correlation: correlation, isCommand: command)
    }
    private func frame(_ bytes: Data) throws -> MQTTFrame {
        var decoder = MQTTFrameDecoder()
        let frames = try decoder.append(bytes)
        XCTAssertEqual(frames.count, 1)
        return frames[0]
    }
    private var connack: MQTTFrame { MQTTFrame(header: 0x20, body: Data([0, 0, 0])) }
    private var suback: MQTTFrame { MQTTFrame(header: 0x90, body: Data([0, 1, 0, 0])) }

    func testMQTTFragmentedAndCoalescedPackets() throws {
        let packet = try MQTTCodec.packet(0x30, Data(repeating: 5, count: 350))
        var decoder = MQTTFrameDecoder(), frames: [MQTTFrame] = []
        for byte in packet { frames += try decoder.append(Data([byte])) }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].body.count, 350)
        XCTAssertEqual(try decoder.append(Data([0xd0, 0, 0xd0, 0])).count, 2)
    }

    func testMQTTMalformedLengthHeadersAndOversizedFramesFail() throws {
        let invalid: [[UInt8]] = [[0x20, 0x80, 0], [0x20, 0xff, 0xff, 0xff, 0xff], [0x21, 0], [0, 0], [0x20, 0x80, 0x80, 0x40]]
        for bytes in invalid {
            var decoder = MQTTFrameDecoder()
            XCTAssertThrowsError(try decoder.append(Data(bytes)))
        }
        XCTAssertThrowsError(try MQTTCodec.variable(-1))
        XCTAssertThrowsError(try MQTTCodec.variable(268435456))
    }

    func testMQTTOnlyPublishesOnceAfterSuccessfulSubscription() throws {
        var state = try session(command: true)
        XCTAssertEqual(state.connect.first, 0x10)
        let subscribe = try state.receive(connack)
        XCTAssertEqual(subscribe.count, 1)
        XCTAssertEqual(subscribe[0].first, 0x82)
        let publish = try state.receive(suback)
        XCTAssertEqual(publish.count, 1)
        XCTAssertEqual(publish[0].first, 0x30)
        let decoded = try MQTTCodec.decodePublish(frame(publish[0]))
        XCTAssertEqual(decoded.topic, topic("task/pause"))
        XCTAssertEqual(decoded.correlation, correlation)
        XCTAssertEqual(decoded.payload, Data([1, 2]))
        XCTAssertThrowsError(try state.receive(suback))
    }

    func testMQTTAuthenticationAndSubscriptionRejectionsStopBeforePublish() throws {
        var auth = try session()
        XCTAssertThrowsError(try auth.receive(MQTTFrame(header: 0x20, body: Data([0, 0x87, 0]))))
        var subscription = try session()
        _ = try subscription.receive(connack)
        XCTAssertThrowsError(try subscription.receive(MQTTFrame(header: 0x90, body: Data([0, 1, 0, 0x80]))))
        var premature = try session()
        XCTAssertThrowsError(try premature.receive(suback))
    }

    func testMQTTRejectsCrossDeviceAndNonAllowlistedTopics() throws {
        for suffix in ["config/set", "task/force_end", "clean/plan/start", "../task/pause", "task/pause/response"] {
            XCTAssertThrowsError(try session(command: true, suffix: suffix))
        }
        XCTAssertThrowsError(try session(command: false, suffix: "task/pause"))
        XCTAssertThrowsError(try session(command: true, suffix: "map/get_map"))
        XCTAssertThrowsError(try MQTTSession(uuid: uuid, token: "test", device: device, topic: "/other/\(device.id)/task/pause", payload: Data(), correlation: correlation, isCommand: true))
        _ = try session(suffix: "map/get_map")
        _ = try session(suffix: "clean/current_clean_task/get")
    }

    func testMQTTIgnoresUnrelatedCorrelationAndRetainedMessages() throws {
        var state = try session()
        _ = try state.receive(connack); _ = try state.receive(suback)
        let expected = topic() + "/response"
        func reply(_ target: String, correlation: Data, retained: Bool = false) throws -> MQTTFrame {
            let packet = try MQTTCodec.publish(topic: target, responseTopic: "unused", payload: Data([7]), correlation: correlation)
            let decoded = try frame(packet)
            return MQTTFrame(header: retained ? 0x31 : 0x30, body: decoded.body)
        }
        _ = try state.receive(reply("/unrelated", correlation: correlation))
        _ = try state.receive(reply(expected, correlation: Data([9])))
        _ = try state.receive(reply(expected, correlation: correlation, retained: true))
        XCTAssertNil(state.response)
        _ = try state.receive(reply(expected, correlation: correlation))
        XCTAssertEqual(state.response, Data([7]))
    }

    func testMQTTMultibytePropertiesAndQoS1Acknowledgement() throws {
        let responseTopic = topic() + "/response"
        let properties = try Data([38]) + MQTTCodec.text("label") + MQTTCodec.text(String(repeating: "x", count: 200)) + Data([9]) + MQTTCodec.binary(correlation)
        let body = try MQTTCodec.text(responseTopic) + Data([0, 7]) + MQTTCodec.variable(properties.count) + properties + Data([42])
        var state = try session()
        _ = try state.receive(connack); _ = try state.receive(suback)
        let acknowledgement = try state.receive(MQTTFrame(header: 0x32, body: body))
        XCTAssertEqual(acknowledgement, [Data([0x40, 2, 0, 7])])
        XCTAssertEqual(state.response, Data([42]))
    }

    func testMQTTMalformedPropertiesAndQoSFail() throws {
        let base = try MQTTCodec.text("test")
        let duplicate = try Data([9]) + MQTTCodec.binary(Data([1])) + Data([9]) + MQTTCodec.binary(Data([2]))
        XCTAssertThrowsError(try MQTTCodec.decodePublish(MQTTFrame(header: 0x30, body: base + MQTTCodec.variable(duplicate.count) + duplicate)))
        XCTAssertThrowsError(try MQTTCodec.decodePublish(MQTTFrame(header: 0x34, body: base)))
        XCTAssertThrowsError(try MQTTCodec.decodePublish(MQTTFrame(header: 0x30, body: base + Data([1, 0x7f]))))
        XCTAssertThrowsError(try MQTTCodec.decodePublish(MQTTFrame(header: 0x30, body: base + Data([5, 9]))))
    }

    func testMQTTFailureAfterPublicationIsUnknownAndNeverRetried() async throws {
        let channel = OfflineMQTTChannel(incoming: [Data([0x20, 3, 0, 0, 0]), Data([0x90, 4, 0, 1, 0, 0])])
        do {
            _ = try await NarwalMQTT.run(channel, session: session(command: true), isCommand: true)
            XCTFail("Expected a missing command response")
        } catch ConnectorError.outcomeUnknown {} catch { XCTFail("Expected an unknown command outcome") }
        XCTAssertEqual(channel.sent.filter { $0.first == 0x30 }.count, 1)
        XCTAssertEqual(channel.sent.map { $0.first! }, [0x10, 0x82, 0x30])
        XCTAssertTrue(channel.closed)
    }

    func testMQTTFailureDuringPublishWriteIsAlsoUnknown() async throws {
        let channel = OfflineMQTTChannel(incoming: [Data([0x20, 3, 0, 0, 0]), Data([0x90, 4, 0, 1, 0, 0])], failPublication: true)
        do {
            _ = try await NarwalMQTT.run(channel, session: session(command: true), isCommand: true)
            XCTFail("Expected write failure")
        } catch ConnectorError.outcomeUnknown {} catch { XCTFail("Expected an unknown command outcome") }
        XCTAssertEqual(channel.sent.filter { $0.first == 0x30 }.count, 1)
        XCTAssertTrue(channel.closed)
    }

    func testMQTTFailureBeforePublishIsDefiniteAndClosesChannel() async throws {
        let channel = OfflineMQTTChannel(incoming: [Data([0x20, 3, 0, 0x87, 0])])
        do {
            _ = try await NarwalMQTT.run(channel, session: session(command: true), isCommand: true)
            XCTFail("Expected authentication rejection")
        } catch ConnectorError.outcomeUnknown { XCTFail("No command was sent") } catch {}
        XCTAssertEqual(channel.sent.map { $0.first! }, [0x10])
        XCTAssertTrue(channel.closed)
    }

    func testMQTTPreflightAfterHandshakeCanPreventPublication() async throws {
        let channel = OfflineMQTTChannel(incoming: [Data([0x20, 3, 0, 0, 0]), Data([0x90, 4, 0, 1, 0, 0])])
        let guardState = OfflinePreflight(rejectAt: 2)
        do {
            _ = try await NarwalMQTT.run(channel, session: session(command: true), isCommand: true,
                                        preflight: { try await guardState.check() })
            XCTFail("A revoked session must prevent publication")
        } catch ConnectorError.outcomeUnknown { XCTFail("No command was sent") } catch {}
        let checks = await guardState.count
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(channel.sent.map { $0.first! }, [0x10, 0x82])
        XCTAssertTrue(channel.closed)
    }

    func testMQTTPreflightBeforeConnectWithholdsCredentials() async throws {
        let channel = OfflineMQTTChannel(incoming: [])
        let guardState = OfflinePreflight(rejectAt: 1)
        do {
            _ = try await NarwalMQTT.run(channel, session: session(), isCommand: false,
                                        preflight: { try await guardState.check() })
            XCTFail("An expired policy must prevent CONNECT")
        } catch {}
        XCTAssertTrue(channel.sent.isEmpty)
        XCTAssertTrue(channel.closed)
    }
}

private actor OfflinePreflight {
    private let rejectAt: Int
    private(set) var count = 0
    init(rejectAt: Int) { self.rejectAt = rejectAt }
    func check() throws {
        count += 1
        if count == rejectAt { throw ConnectorError.invalid("Offline revoked authorization") }
    }
}

/// An in-memory stream; its test methods are called serially by the exchange.
private final class OfflineMQTTChannel: MQTTChannel, @unchecked Sendable {
    private var incoming: [Data]
    private let failPublication: Bool
    private(set) var sent: [Data] = []
    private(set) var closed = false
    init(incoming: [Data], failPublication: Bool = false) { self.incoming = incoming; self.failPublication = failPublication }
    func send(_ data: Data) async throws {
        sent.append(data)
        if failPublication && data.first == 0x30 { throw ConnectorError.invalid("Offline write failure") }
    }
    func read(minimum: Int, maximum: Int) async throws -> Data {
        incoming.isEmpty ? Data() : incoming.removeFirst()
    }
    func close() { closed = true }
}
