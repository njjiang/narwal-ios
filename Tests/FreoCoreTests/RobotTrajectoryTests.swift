import Foundation
import XCTest
@testable import FreoCore

/// Synthetic wire fixtures only: no household geometry or account information.
enum RouteFixture {
    static func integer(_ value: UInt64) -> Data {
        var value = value, data = Data()
        repeat { let byte = UInt8(value & 127); value >>= 7; data.append(byte | (value == 0 ? 0 : 128)) } while value != 0
        return data
    }
    static func number(_ tag: Int, _ value: UInt64) -> Data { integer(UInt64(tag << 3)) + integer(value) }
    static func bytes(_ tag: Int, _ data: Data) -> Data { integer(UInt64(tag << 3 | 2)) + integer(UInt64(data.count)) + data }
    static func float(_ value: Float) -> Data {
        var bits = value.bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Data($0) }
    }
    static func path(_ points: [(Float, Float)]) -> Data {
        bytes(1, points.reduce(Data()) { $0 + float($1.0) }) + bytes(2, points.reduce(Data()) { $0 + float($1.1) })
    }
    static func info(_ index: UInt64, _ type: UInt64) -> Data { bytes(31, number(1, type) + number(2, index)) }
    static let deviceID = String(repeating: "a", count: 32)
    static func snapshot(points: [(Float, Float)] = [(0, 10), (1, 9), (2, 8)],
                         at: Date = Date(), sequence: UInt64 = 1, revision: UInt32 = 1,
                         device: String = deviceID, format: UInt64 = 1, extra: Data = Data(),
                         replacePath: Data? = nil, replaceInfo: Data? = nil,
                         timestamp: UInt64? = nil, pixels: [UInt32]? = nil) -> MapSnapshot {
        let border = number(2, 10) + number(4, 10)
        let map = number(1, 1) + number(2, 1) + number(33, UInt64(revision)) + number(4, 10) + number(5, 10) + bytes(6, border)
        let route = replacePath ?? path(points)
        let payload = map + number(15, format) + bytes(format == 1 ? 13 : 14, route) +
            number(22, sequence) + number(36, timestamp ?? UInt64(at.timeIntervalSince1970 * 1000)) +
            (replaceInfo ?? info(0, 4)) + extra
        let floorplan = Floorplan(mapID: 1, width: 10, height: 10, resolution: 60,
            rooms: [RobotRoom(id: 1, name: "Synthetic room")], pixels: pixels ?? Array(repeating: 0x101, count: 100), mapRevision: revision)
        return MapSnapshot(productKey: "EHf6cRNRGT", deviceID: device, mapID: 1,
            mapVersion: 1, editVersion: revision, capturedAt: at, floorplan: floorplan, staticMapPayload: payload)
    }
}

final class RobotTrajectoryTests: XCTestCase {
    func testForwardTypeTransitionsShareBoundaryPointAndTransformToDisplayGrid() throws {
        let pose = RouteFixture.bytes(24, RouteFixture.bytes(1, Data([0x0d]) + RouteFixture.float(2) + Data([0x15]) + RouteFixture.float(8)))
        let snapshot = RouteFixture.snapshot(points: [(0, 10), (1, 9), (2, 8), (3, 7)], extra: pose,
            replaceInfo: RouteFixture.info(1, 1) + RouteFixture.info(2, 4))
        let result = try NarwalCodec.trajectory(snapshot: snapshot)
        XCTAssertEqual(result.points, [.init(x: 0.5, y: 0.5), .init(x: 1.5, y: 1.5), .init(x: 2.5, y: 2.5), .init(x: 3.5, y: 3.5)])
        XCTAssertEqual(result.segments.map(\.typeCode), [0, 1, 4])
        XCTAssertEqual(result.segments.map(\.id), [0, 1, 2])
        XCTAssertEqual(result.segments[0].points.last, result.segments[1].points.first)
        XCTAssertEqual(result.segments[1].points.last, result.segments[2].points.first)
        XCTAssertEqual(result.pose?.point, RobotPathPoint(x: 2.5, y: 2.5))
        XCTAssertNil(result.unavailableReason)
    }

    func testEncodedProtobufFormatHasIdenticalMeaningAndUnknownTypeIsRetained() throws {
        let direct = try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot(replaceInfo: RouteFixture.info(0, 932)))
        let encoded = try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot(format: 2, replaceInfo: RouteFixture.info(0, 932)))
        XCTAssertEqual(direct.points, encoded.points); XCTAssertEqual(direct.segments, encoded.segments)
        XCTAssertEqual(encoded.segments.first?.typeCode, 932)
    }

    func testRepeatedPackedAndUnpackedFloatFieldsConcatenateInWireOrder() throws {
        let x = RouteFixture.bytes(1, RouteFixture.float(0)) + Data([0x0d]) + RouteFixture.float(1) + RouteFixture.bytes(1, RouteFixture.float(2))
        let y = Data([0x15]) + RouteFixture.float(10) + RouteFixture.bytes(2, RouteFixture.float(9) + RouteFixture.float(8))
        let result = try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot(replacePath: x + y))
        let expected = try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot())
        XCTAssertEqual(result.points, expected.points); XCTAssertEqual(result.segments, expected.segments)
    }

    func testUnsupportedCompressionAndCurvesNeverBecomeStraightCleaningLines() throws {
        for snapshot in [RouteFixture.snapshot(format: 3), RouteFixture.snapshot(extra: RouteFixture.bytes(43, Data()))] {
            let result = try NarwalCodec.trajectory(snapshot: snapshot)
            XCTAssertNotNil(result.unavailableReason); XCTAssertTrue(result.points.isEmpty); XCTAssertTrue(result.segments.isEmpty)
        }
    }

    func testRejectsInvalidFloatsCountsStateIndicesAndDuplicateSingletons() {
        let invalid = [
            RouteFixture.snapshot(points: [(.nan, 10), (1, 9)]),
            RouteFixture.snapshot(points: [(0, .infinity), (1, 9)]),
            RouteFixture.snapshot(points: [(0, 10), (100, 9)]),
            RouteFixture.snapshot(replacePath: RouteFixture.bytes(1, RouteFixture.float(0))),
            RouteFixture.snapshot(replacePath: RouteFixture.bytes(1, Data([0])) + RouteFixture.bytes(2, Data([0]))),
            RouteFixture.snapshot(replaceInfo: RouteFixture.info(2, 4) + RouteFixture.info(1, 1)),
            RouteFixture.snapshot(replaceInfo: RouteFixture.info(1, 4) + RouteFixture.info(1, 1)),
            RouteFixture.snapshot(replaceInfo: RouteFixture.info(3, 4)),
            RouteFixture.snapshot(extra: RouteFixture.number(36, 3)),
            RouteFixture.snapshot(extra: RouteFixture.bytes(13, Data())),
            RouteFixture.snapshot(extra: RouteFixture.bytes(14, Data([1])))
        ]
        for snapshot in invalid { XCTAssertThrowsError(try NarwalCodec.trajectory(snapshot: snapshot)) }
    }

    func testMalformedOrOversizedFramesRejectWithoutUnboundedAllocation() {
        let tooMany = RouteFixture.bytes(1, Data(repeating: 0, count: 400_004)) + RouteFixture.bytes(2, Data(repeating: 0, count: 400_004))
        XCTAssertThrowsError(try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot(replacePath: tooMany)))
        XCTAssertThrowsError(try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot(extra: Data(repeating: 0, count: 1024 * 1024))))
        XCTAssertThrowsError(try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot(extra: Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f]))))
    }

    func testMissingTypesStayUnknownAndMissingPathOrUnverifiedRotationIsExplicit() throws {
        let unknown = try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot(replaceInfo: Data()))
        XCTAssertEqual(unknown.segments.map(\.typeCode), [0])
        let rotated = try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot(extra: RouteFixture.number(25, 90)))
        XCTAssertNotNil(rotated.unavailableReason); XCTAssertTrue(rotated.segments.isEmpty)
        let empty = try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot(points: [], replaceInfo: Data()))
        XCTAssertTrue(empty.points.isEmpty); XCTAssertTrue(empty.segments.isEmpty)
    }

    func testUnsignedTimestampAndSequenceAreNotTruncatedOrTreatedAsRunIDs() throws {
        let result = try NarwalCodec.trajectory(snapshot: RouteFixture.snapshot(sequence: UInt64.max, timestamp: UInt64.max))
        XCTAssertEqual(result.sequenceID, UInt64.max); XCTAssertEqual(result.deviceTimestampMilliseconds, UInt64.max)
    }
}
