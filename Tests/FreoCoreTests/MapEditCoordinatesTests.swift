import Foundation
import XCTest
@testable import FreoCore

final class MapEditCoordinatesTests: XCTestCase {
    private func integer(_ value: UInt64) -> Data {
        var value = value, data = Data()
        repeat { let byte = UInt8(value & 127); value >>= 7; data.append(byte | (value == 0 ? 0 : 128)) } while value != 0
        return data
    }
    private func number(_ tag: Int, _ value: Int) -> Data { integer(UInt64(tag << 3)) + integer(UInt64(bitPattern: Int64(value))) }
    private func bytes(_ tag: Int, _ value: Data) -> Data { integer(UInt64(tag << 3 | 2)) + integer(UInt64(value.count)) + value }
    private func border(bottom: Int = -20, top: Int = -14, left: Int = 12, right: Int = 20) -> Data {
        number(1, bottom) + number(2, top) + number(3, left) + number(4, right)
    }
    private func snapshot(border supplied: Data? = nil, rotation: Int? = 0, extra: Data = Data(), width: Int = 8, height: Int = 6, productKey: String = "EHf6cRNRGT") -> MapSnapshot {
        var payload = number(1, 9) + number(4, width) + number(5, height) + bytes(6, supplied ?? border())
        if let rotation { payload += number(25, rotation) }
        payload += extra
        let floor = Floorplan(mapID: 9, width: width, height: height, resolution: 60,
                              rooms: [RobotRoom(id: 1, name: "Room")], pixels: Array(repeating: 257, count: max(0, width * height)))
        return MapSnapshot(productKey: productKey, deviceID: String(repeating: "a", count: 32), mapID: 9,
                           mapVersion: 3, editVersion: 4, capturedAt: Date(), floorplan: floor, staticMapPayload: payload)
    }

    func testGridEdgesUseBorderTranslationAndOneYFlip() throws {
        let transform = try MapEditCoordinates(snapshot: snapshot())
        XCTAssertEqual(try transform.point(RoomGridPoint(x: 0, y: 0)), MapEditPoint(x: 11.5, y: -13.5))
        XCTAssertEqual(try transform.point(RoomGridPoint(x: 8, y: 6)), MapEditPoint(x: 19.5, y: -19.5))
        XCTAssertEqual(try transform.point(RoomGridPoint(x: 3, y: 2)), MapEditPoint(x: 14.5, y: -15.5))
        // Official pixel centers are integers; our integer edges are halfway
        // between them, rather than silently selecting a row/column of centers.
        XCTAssertEqual(try transform.point(RoomGridPoint(x: 4, y: 3)), MapEditPoint(x: 15.5, y: -16.5))
    }

    func testResolutionAndOriginDoNotChangeProtocolGridUnits() throws {
        let origin = Data([0x0d, 0, 0, 0x80, 0x3f, 0x15, 0, 0, 0, 0x40])
        let transform = try MapEditCoordinates(snapshot: snapshot(rotation: nil, extra: number(3, 60) + bytes(7, origin)))
        XCTAssertEqual(try transform.point(RoomGridPoint(x: 1, y: 1)), MapEditPoint(x: 12.5, y: -14.5))
    }

    func testOmittedZeroBorderScalarsFollowOfficialGetterDefaults() throws {
        let transform = try MapEditCoordinates(snapshot: snapshot(border: number(2, 6) + number(4, 8), rotation: nil))
        XCTAssertEqual(try transform.point(RoomGridPoint(x: 0, y: 0)), MapEditPoint(x: -0.5, y: 6.5))
        XCTAssertEqual(try transform.point(RoomGridPoint(x: 8, y: 6)), MapEditPoint(x: 7.5, y: 0.5))
        XCTAssertThrowsError(try MapEditCoordinates(snapshot: snapshot(border: number(2, 6))))
    }

    func testUnverifiedRotationAndInconsistentBorderExtentsFailClosed() throws {
        for angle in [90, 180, 270, 360, -90] {
            XCTAssertThrowsError(try MapEditCoordinates(snapshot: snapshot(rotation: angle)))
        }
        XCTAssertThrowsError(try MapEditCoordinates(snapshot: snapshot(border: border(right: 19))))
        XCTAssertThrowsError(try MapEditCoordinates(snapshot: snapshot(border: border(top: -15))))
        XCTAssertThrowsError(try MapEditCoordinates(snapshot: snapshot(productKey: "other")))
    }

    func testConsistentCenterSpanStillUsesLeftAndTopDirectly() throws {
        let transform = try MapEditCoordinates(snapshot: snapshot(border: border(top: -15, right: 19)))
        XCTAssertEqual(try transform.point(RoomGridPoint(x: 0, y: 0)), MapEditPoint(x: 11.5, y: -14.5))
        XCTAssertEqual(try transform.point(RoomGridPoint(x: 8, y: 6)), MapEditPoint(x: 19.5, y: -20.5))
    }

    func testOutOfBoundsDividerFailsWithoutClamping() throws {
        let transform = try MapEditCoordinates(snapshot: snapshot())
        for point in [RoomGridPoint(x: -1, y: 0), RoomGridPoint(x: 0, y: -1), RoomGridPoint(x: 9, y: 2), RoomGridPoint(x: 4, y: 7)] {
            XCTAssertThrowsError(try transform.point(point))
        }
    }

    func testMissingDuplicateMalformedAndOversizedMetadataRejected() throws {
        for invalid in [Data(), number(1, -20), border() + number(3, 12),
                        border() + bytes(1, Data()), border() + Data([0x80]),
                        border(left: 8_000_001, right: 8_000_009)] {
            XCTAssertThrowsError(try MapEditCoordinates(snapshot: snapshot(border: invalid)))
        }
        for extra in [bytes(6, border()), number(25, 0), number(4, 8), number(1, 9), Data([0x0f]),
                      bytes(101, Data(repeating: 1, count: 1024 * 1024))] {
            XCTAssertThrowsError(try MapEditCoordinates(snapshot: snapshot(extra: extra)))
        }
    }
}
