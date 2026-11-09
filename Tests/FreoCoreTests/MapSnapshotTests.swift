import Foundation
import XCTest
@testable import FreoCore

final class MapSnapshotTests: XCTestCase {
    private let robot = RobotDevice(id: String(repeating: "a", count: 32), productKey: "EHf6cRNRGT", name: "Robot")
    private func integer(_ n: UInt64) -> Data {
        var n = n, data = Data()
        repeat { let low = UInt8(n & 127); n >>= 7; data.append(low | (n == 0 ? 0 : 128)) } while n != 0
        return data
    }
    private func number(_ tag: Int, _ n: UInt64) -> Data { integer(UInt64(tag << 3)) + integer(n) }
    private func bytes(_ tag: Int, _ data: Data) -> Data { integer(UInt64(tag << 3 | 2)) + integer(UInt64(data.count)) + data }
    private func frame(_ payload: Data) -> Data { Data([1]) + integer(UInt64(payload.count)) + payload }
    private func response(_ map: Data) -> Data { frame(number(1, 1) + bytes(2, map)) }
    private func baseMap() -> Data {
        // zlib of {1: packed [32]}, a one-cell nonblank synthetic grid.
        let grid = Data([0x78, 0x9c, 0xe3, 0x62, 0x54, 0, 0, 0, 0x43, 0, 0x2c])
        return number(1, 17) + number(3, 60) + number(4, 1) + number(5, 1) + bytes(17, grid)
    }
    private func revisions(_ map: UInt64 = 3, _ edit: UInt64 = 1077) -> Data { number(2, map) + number(33, edit) }

    func testSnapshotPreservesExactUnknownFieldsAndValidatedDisplay() throws {
        let unknown = bytes(109, Data([0, 255, 1, 2])) + number(110, UInt64.max) + number(110, 7)
        let map = number(33, 1077) + unknown + baseMap() + number(2, 3)
        let capturedAt = Date(timeIntervalSince1970: 1234)
        let snapshot = try NarwalCodec.mapSnapshot(response(map), device: robot, capturedAt: capturedAt)
        XCTAssertEqual(snapshot.staticMapPayload, map)
        XCTAssertEqual(snapshot.mapID, 17)
        XCTAssertEqual(snapshot.mapVersion, 3)
        XCTAssertEqual(snapshot.editVersion, 1077)
        XCTAssertEqual(snapshot.capturedAt, capturedAt)
        XCTAssertEqual(snapshot.floorplan.mapID, snapshot.mapID)
        XCTAssertEqual(snapshot.floorplan.pixels, [32])
        XCTAssertEqual(snapshot.floorplan.width, 1)
        XCTAssertEqual(snapshot.floorplan.height, 1)
        XCTAssertEqual(snapshot.floorplan.mapRevision, 1077)
        XCTAssertEqual(snapshot.productKey, robot.productKey)
        XCTAssertEqual(snapshot.deviceID, robot.id)
    }

    func testIdentityEnvelopeIsExcludedWithoutReencodingStaticPayload() throws {
        let map = baseMap() + revisions()
        let body = number(1, 1) + bytes(2, map)
        let account = String(repeating: "b", count: 32)
        for framed in [frame(body), try NarwalCodec.identity(uuid: account) + body,
                       Data([1, 2]) + body] {
            XCTAssertEqual(try NarwalCodec.mapSnapshot(framed, device: robot).staticMapPayload, map)
        }
    }

    func testMissingRevisionsDoNotBreakOrdinaryFloorplanDisplay() throws {
        for missing in [Data(), number(2, 3), number(33, 1077)] {
            let payload = response(baseMap() + missing)
            XCTAssertEqual(try NarwalCodec.floorplan(payload).pixels, [32])
            XCTAssertThrowsError(try NarwalCodec.mapSnapshot(payload, device: robot))
        }
        let explicitZero = try NarwalCodec.mapSnapshot(response(baseMap() + revisions(0, 0)), device: robot)
        XCTAssertEqual(explicitZero.mapVersion, 0)
        XCTAssertEqual(explicitZero.editVersion, 0)
    }

    func testRoomAndFloorplanRevisionAreOptionalButBoundedWhenPresent() throws {
        XCTAssertNil(try NarwalCodec.rooms(response(baseMap())).mapRevision)
        XCTAssertNil(try NarwalCodec.floorplan(response(baseMap())).mapRevision)
        for revision: UInt64 in [0, 1, UInt64(UInt32.max)] {
            let raw = response(baseMap() + number(33, revision))
            XCTAssertEqual(try NarwalCodec.rooms(raw).mapRevision, UInt32(revision))
            XCTAssertEqual(try NarwalCodec.floorplan(raw).mapRevision, UInt32(revision))
        }
        for revision in [number(33, 1) + number(33, 1), bytes(33, Data()), number(33, UInt64(UInt32.max) + 1)] {
            XCTAssertThrowsError(try NarwalCodec.rooms(response(baseMap() + revision)))
            XCTAssertThrowsError(try NarwalCodec.floorplan(response(baseMap() + revision)))
        }
    }

    func testSnapshotRejectsDuplicateMistypedAndOutOfRangeRevisions() throws {
        let invalid = [
            revisions() + number(2, 3), revisions() + number(33, 1077),
            bytes(2, Data()) + number(33, 1), number(2, 1) + bytes(33, Data()),
            revisions(UInt64(UInt32.max) + 1, 1), revisions(1, UInt64(UInt32.max) + 1),
            revisions(UInt64.max, 1), revisions(1, UInt64.max)
        ]
        for value in invalid {
            XCTAssertThrowsError(try NarwalCodec.mapSnapshot(response(baseMap() + value), device: robot))
        }
        let maximum = try NarwalCodec.mapSnapshot(response(baseMap() + revisions(UInt64(UInt32.max), UInt64(UInt32.max))), device: robot)
        XCTAssertEqual(maximum.mapVersion, UInt32.max)
        XCTAssertEqual(maximum.editVersion, UInt32.max)
    }

    func testSnapshotScopeUsesDeviceProductAndMapInsteadOfDisplayName() throws {
        let snapshot = try NarwalCodec.mapSnapshot(response(baseMap() + revisions()), device: robot)
        let renamed = RobotDevice(id: robot.id, productKey: robot.productKey, name: "Renamed")
        XCTAssertTrue(snapshot.matches(device: renamed, mapID: 17))
        XCTAssertFalse(snapshot.matches(device: renamed, mapID: 18))
        XCTAssertFalse(snapshot.matches(device: RobotDevice(id: String(repeating: "b", count: 32), productKey: robot.productKey, name: robot.name), mapID: 17))
        XCTAssertFalse(snapshot.matches(device: RobotDevice(id: robot.id, productKey: "otherProduct", name: robot.name), mapID: 17))
        let badDevices = [
            RobotDevice(id: "demo", productKey: robot.productKey, name: "Demo"),
            RobotDevice(id: String(repeating: "z", count: 32), productKey: robot.productKey, name: "Bad"),
            RobotDevice(id: robot.id, productKey: "bad/topic", name: "Bad"),
            RobotDevice(id: robot.id, productKey: "product\n", name: "Bad"),
            RobotDevice(id: robot.id, productKey: String(repeating: "A", count: 33), name: "Bad")
        ]
        for device in badDevices {
            XCTAssertThrowsError(try NarwalCodec.mapSnapshot(response(baseMap() + revisions()), device: device))
        }
    }

    func testSnapshotRequiresSuccessAndValidBoundedFloorplan() throws {
        let valid = baseMap() + revisions()
        for invalid in [frame(number(1, 2) + bytes(2, valid)), response(revisions()),
                        response(valid + number(1, 18)), response(valid + number(4, 0)),
                        response(valid + bytes(111, Data(repeating: 0, count: 1024 * 1024)))] {
            XCTAssertThrowsError(try NarwalCodec.mapSnapshot(invalid, device: robot))
        }
    }

    func testSnapshotServiceRequiresAuthenticatedSessionBeforeAnyRequest() async {
        let service = NarwalService()
        do {
            _ = try await service.mapSnapshot(device: robot)
            XCTFail("Unsigned snapshot should not reach a network request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Sign in"))
        }
    }
}
