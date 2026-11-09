import XCTest
@testable import FreoCore

final class RoomDoorReadbackTests: XCTestCase {
    private func integer(_ input: UInt64) -> Data {
        var input = input, output = Data()
        repeat { let part = UInt8(input & 127); input >>= 7; output.append(part | (input == 0 ? 0 : 128)) } while input != 0
        return output
    }
    private func n(_ tag: Int, _ value: UInt64) -> Data { integer(UInt64(tag << 3)) + integer(value) }
    private func b(_ tag: Int, _ value: Data) -> Data { integer(UInt64(tag << 3 | 2)) + integer(UInt64(value.count)) + value }
    private func point(_ x: Int, _ y: Int) -> Data {
        n(1, UInt64(bitPattern: Int64(x))) + n(2, UInt64(bitPattern: Int64(y)))
    }
    private func door(_ ids: [Int], _ points: [(Int, Int)] = [(0, 0), (0, 10)], extra: Data = Data(), packed: Bool = true) -> Data {
        var data = packed ? b(1, ids.reduce(into: Data()) { $0 += integer(UInt64($1)) })
                          : ids.reduce(into: Data()) { $0 += n(1, UInt64($1)) }
        for (x, y) in points { data += b(2, point(x, y)) }
        return data + extra
    }
    private func snapshot(_ ids: [Int], _ doors: [Data], rawOverride: Data? = nil) -> MapSnapshot {
        let raw = rawOverride ?? doors.reduce(into: Data()) { $0 += b(11, $1) }
        let map = Floorplan(mapID: 1, width: 2, height: 2, resolution: 60,
                            rooms: ids.map { RobotRoom(id: $0, name: "Room \($0)") }, pixels: [0, 0, 0, 0])
        return MapSnapshot(productKey: "EHf6cRNRGT", deviceID: String(repeating: "a", count: 32),
            mapID: 1, mapVersion: 1, editVersion: 2, capturedAt: Date(), floorplan: map, staticMapPayload: raw)
    }
    private var merge: [RoomMapOperation] { [.merge(roomID1: 3, roomID2: 8, newRoomID: 3)] }
    private var split: [RoomMapOperation] { [.split(start: .init(x: 0, y: 0), end: .init(x: 0, y: 10), leftRoomID: 3, rightRoomID: 8)] }

    // Reproduces the Living room failure: the firmware's old summary omitted
    // the left part of an existing contact; splitting regenerated that part.
    private func regeneratedSnapshot(split: Bool, changedDoor: Data? = nil) -> MapSnapshot {
        let pixels: [UInt32] = (0..<100).map { i in
            let x = i % 10, y = 9 - i / 10
            let id = y >= 6 ? 4 : (split && x < 4 ? 8 : 3)
            return UInt32(id) << 8 | 1
        }
        let ids = split ? [3, 4, 8] : [3, 4]
        let map = Floorplan(mapID: 1, width: 10, height: 10, resolution: 60,
                            rooms: ids.map { .init(id: $0, name: "Room \($0)") }, pixels: pixels)
        var raw = n(1, 1) + n(4, 10) + n(5, 10)
        raw += b(6, n(1, 0) + n(2, 10) + n(3, 0) + n(4, 10))
        let records = split
            ? [door([3, 4], [(4, 5), (9, 5)]), changedDoor ?? door([8, 4], [(0, 5), (3, 5)])]
            : [door([3, 4], [(5, 5), (9, 5)])]
        for record in records { raw += b(11, record) }
        return MapSnapshot(productKey: "EHf6cRNRGT", deviceID: String(repeating: "a", count: 32),
            mapID: 1, mapVersion: 1, editVersion: split ? 2 : 1, capturedAt: Date(),
            floorplan: map, staticMapPayload: raw)
    }
    func testSplitAcceptsRegeneratedPlainContactProvenByRaster() throws {
        let before = regeneratedSnapshot(split: false), after = regeneratedSnapshot(split: true)
        try RoomDoorReadback.validate(baseline: before, current: after, operations: split, allowsGridRounding: true)
        // Other edit callers retain the original exact verification.
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before, current: after, operations: split))
    }
    func testRegeneratedContactRejectsSettingsAndGeometryOutsideRoomOverlap() {
        let before = regeneratedSnapshot(split: false)
        for changed in [door([8, 4], [(-2, 5), (3, 5)]), door([8, 4], [(0, 3), (3, 3)]),
                        door([8, 4], [(0, 5), (3, 5)], extra: n(3, 1)),
                        door([8, 4], [(0, 5), (3, 5)], extra: n(99, 7))] {
            XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before,
                current: regeneratedSnapshot(split: true, changedDoor: changed), operations: split, allowsGridRounding: true))
        }
    }

    func testRegeneratedContactRequiresTouchingRoomPixels() {
        let baseline = regeneratedSnapshot(split: false)
        let after = regeneratedSnapshot(split: true)
        // Overlapping bounding boxes alone are insufficient evidence of contact.
        var pixels = [UInt32](repeating: 0, count: 100)
        func index(_ x: Int, _ y: Int) -> Int { (9 - y) * 10 + x }
        for (x, y) in [(0, 0), (3, 5)] { pixels[index(x, y)] = 8 << 8 | 1 }
        for (x, y) in [(0, 5), (3, 0)] { pixels[index(x, y)] = 4 << 8 | 1 }
        pixels[index(9, 0)] = 3 << 8 | 1
        let map = Floorplan(mapID: 1, width: 10, height: 10, resolution: 60,
                            rooms: after.floorplan.rooms, pixels: pixels)
        let disconnected = MapSnapshot(productKey: after.productKey, deviceID: after.deviceID,
            mapID: after.mapID, mapVersion: after.mapVersion, editVersion: after.editVersion,
            capturedAt: after.capturedAt, floorplan: map, staticMapPayload: after.staticMapPayload)
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: baseline, current: disconnected,
                                                         operations: split, allowsGridRounding: true))
    }
    func testSplitGroupsMultiplePlainSummariesOfSameNeighbor() throws {
        let before = snapshot([3, 4], [door([3, 4], [(10, 0), (15, 0)]),
                                       door([3, 4], [(15, 0), (20, 0)])])
        let after = snapshot([3, 4, 8], [door([3, 4], [(10, 0), (15, 0)]),
                                         door([8, 4], [(15, 0), (20, 0)]), door([3, 8])])
        try RoomDoorReadback.validate(baseline: before, current: after, operations: split, allowsGridRounding: true)
    }

    func testObservedMergePatternRemovesInternalAndRemapsExternalOnly() throws {
        let stable = door([1, 4], [(10, -5), (20, -5)])
        let before = snapshot([1, 3, 4, 8], [stable, door([3, 8]), door([4, 8], [(-3, 4), (2, 4)])])
        let after = snapshot([1, 3, 4], [door([3, 4], [(-3, 4), (2, 4)]), stable])
        try RoomDoorReadback.validate(baseline: before, current: after, operations: merge)
    }
    func testMergeCanonicalizesPackedAndUnpackedRoomIDOrder() throws {
        let before = snapshot([3, 4, 8], [door([4, 8])])
        let after = snapshot([3, 4], [door([3, 4], packed: false)])
        try RoomDoorReadback.validate(baseline: before, current: after, operations: merge)
    }
    func testRobotAssignedRoomIDsAreDiscoveredWithoutChangingExternalDoors() throws {
        let before = snapshot([3, 4, 8], [door([3, 8]), door([4, 8])])
        try RoomDoorReadback.validate(baseline: before,
            current: snapshot([4, 19], [door([4, 19])]), operations: merge)
        let external = door([3, 4], [(10, -5), (20, -5)])
        try RoomDoorReadback.validate(baseline: snapshot([3, 4], [external]),
            current: snapshot([4, 19, 20], [door([20, 4], [(10, -5), (20, -5)]), door([19, 20])]), operations: split)
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before,
            current: snapshot([5, 19], [door([5, 19])]), operations: merge))
    }
    func testMergeRejectsLostUnselectedAdjacency() {
        let before = snapshot([1, 3, 4, 8], [door([3, 8]), door([1, 4])])
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before, current: snapshot([1, 3, 4], []), operations: merge))
    }
    func testMergeRejectsChangedExternalPointsAndSettings() {
        let before = snapshot([3, 4, 8], [door([4, 8])])
        for changed in [door([3, 4], [(0, 0), (1, 10)]), door([3, 4], extra: n(3, 1)), door([3, 4], extra: n(99, 1))] {
            XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before, current: snapshot([3, 4], [changed]), operations: merge))
        }
    }
    func testMergePreservesUnknownExternalMetadata() throws {
        let extra = n(99, 12) + n(3, 1)
        try RoomDoorReadback.validate(baseline: snapshot([3, 4, 8], [door([4, 8], extra: extra)]),
            current: snapshot([3, 4], [door([4, 3], extra: extra)]), operations: merge)
    }
    func testMergeRejectsRemovingInternalSillOrUnknownSetting() {
        for extra in [n(3, 1), n(4, 2), n(99, 0)] {
            XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: snapshot([3, 8], [door([3, 8], extra: extra)]),
                current: snapshot([3], []), operations: merge))
        }
    }
    func testRenameRequiresExactDoorRecordsButNotRecordOrder() throws {
        let a = door([3, 4]), c = door([3, 8], [(2, 0), (2, 10)])
        let before = snapshot([3, 4, 8], [a, c])
        try RoomDoorReadback.validate(baseline: before, current: snapshot([3, 4, 8], [c, a]), operations: [.rename(roomID: 3, name: "Kitchen")])
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before, current: snapshot([3, 4, 8], [a]), operations: [.rename(roomID: 3, name: "Kitchen")]))
    }
    func testSplitRetainsExternalGeometryAndAllowsExactlyOnCutInternalDoor() throws {
        let external = door([3, 4], [(10, -5), (20, -5)], extra: n(99, 7))
        try RoomDoorReadback.validate(baseline: snapshot([3, 4], [external]),
            current: snapshot([3, 4, 8], [door([8, 4], [(10, -5), (20, -5)], extra: n(99, 7)), door([3, 8])]), operations: split)
    }
    func testSplitRejectsUnrelatedIDLossOrExternalGeometryChange() {
        let before = snapshot([3, 4, 5], [door([3, 4])])
        for changed in [door([8, 5]), door([8, 4], [(1, 0), (1, 10)])] {
            XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before, current: snapshot([3, 4, 5, 8], [changed]), operations: split))
        }
    }
    func testSplitRejectsOffCutOutsideSegmentOrAdditionalDoorSettings() {
        for added in [door([3, 8], [(1, 0), (1, 10)]), door([3, 8], [(0, -1), (0, 10)]),
                      door([3, 8], extra: n(3, 1)), door([3, 8], extra: n(99, 7))] {
            XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: snapshot([3], []), current: snapshot([3, 8], [added]), operations: split))
        }
    }
    func testHalfCellSplitDoesNotInventIntegerRoundingTolerance() {
        let half: [RoomMapOperation] = [.split(start: .init(x: 0.5, y: 0), end: .init(x: 0.5, y: 10), leftRoomID: 3, rightRoomID: 8)]
        for x in [0, 1] {
            XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: snapshot([3], []),
                current: snapshot([3, 8], [door([3, 8], [(x, 0), (x, 10)])]), operations: half))
        }
    }
    func testVerifiedGridRoundingAcceptsHalfCellDoorAndOneCellIncidentSnap() throws {
        let half: [RoomMapOperation] = [.split(start: .init(x: 0.5, y: 0), end: .init(x: 0.5, y: 10),
                                               leftRoomID: 3, rightRoomID: 8)]
        let before = snapshot([3, 4], [door([3, 4], [(10, -5), (20, -5)])])
        for x in [0, 1] {
            try RoomDoorReadback.validate(baseline: before,
                current: snapshot([3, 4, 8], [door([8, 4], [(20, -4), (10, -4)]),
                                             door([3, 8], [(x, 0), (x, 10)])]),
                operations: half, allowsGridRounding: true)
        }
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before,
            current: snapshot([3, 4, 8], [door([8, 4], [(10, -3), (20, -3)]), door([3, 8])]),
            operations: half, allowsGridRounding: true))
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: snapshot([3], []),
            current: snapshot([3, 8], [door([3, 8], [(2, 0), (2, 10)])]),
            operations: half, allowsGridRounding: true))
    }

    func testMergeUsesVerifiedRenumberingForOtherRoomsAndKeepsTheirDoors() throws {
        let before = snapshot([1, 3, 4, 8], [door([3, 8]), door([4, 8]), door([1, 4])])
        let after = snapshot([1, 3, 6], [door([3, 6]), door([1, 6])])
        try RoomDoorReadback.validate(baseline: before, current: after, operations: merge,
                                      allowsGridRounding: true, roomIDMapping: [1: 1, 4: 6])
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before,
            current: snapshot([1, 3, 6], [door([3, 6]), door([1, 6], [(2, 0), (2, 10)])]),
            operations: merge, allowsGridRounding: true, roomIDMapping: [1: 1, 4: 6]))
    }

    func testSplitSubdividesExternalAdjacencyAndMergeCoalescesItsSegments() throws {
        let half: [RoomMapOperation] = [.split(start: .init(x: 0.5, y: -5), end: .init(x: 0.5, y: 10),
                                               leftRoomID: 3, rightRoomID: 8)]
        let before = snapshot([3, 4], [door([3, 4], [(-5, 0), (5, 0)])])
        let after = snapshot([3, 4, 8], [door([3, 4], [(-5, 0), (1, 0)]),
            door([4, 8], [(0, 0), (5, 0)]), door([3, 8], [(1, -5), (1, 10)])])
        try RoomDoorReadback.validate(baseline: before, current: after, operations: half,
                                      allowsGridRounding: true)
        let merged = snapshot([3, 4], [door([3, 4], [(-5, 0), (5, 0)])])
        try RoomDoorReadback.validate(baseline: after, current: merged, operations: merge,
                                      allowsGridRounding: true)
        let missing = snapshot([3, 4, 8], [door([3, 4], [(-5, 0), (1, 0)]),
                                           door([3, 8], [(1, -5), (1, 10)])])
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before, current: missing,
                                                           operations: half, allowsGridRounding: true))
    }

    func testDuplicateOrUnknownIDsAndCoincidentPointsRejected() {
        for malformed in [door([3, 3]), door([3, 7]), door([3, 8], [(0, 0), (0, 0)]), door([3, 8], [(0, 0)])] {
            XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: snapshot([3, 8], [malformed]), current: snapshot([3], []), operations: merge))
        }
    }
    func testMalformedAndOversizedMetadataRejected() {
        for raw in [Data([0x5a, 0x80]), n(11, 1), Data(repeating: 0, count: 1_048_577),
                    Data([0x5a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02])] {
            XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: snapshot([3, 8], [], rawOverride: raw), current: snapshot([3], []), operations: merge))
        }
    }
    func testNonFiniteAngleAndDuplicateScalarSettingsRejected() {
        for extra in [Data([0x3d, 0, 0, 0x80, 0x7f]), n(3, 0) + n(3, 1)] {
            XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: snapshot([3, 8], [door([3, 8], extra: extra)]), current: snapshot([3], []), operations: merge))
        }
    }
    func testUnsupportedBatchedMutationsAndInvalidCatalogRejected() {
        let before = snapshot([3, 8], [door([3, 8])]), after = snapshot([3], [])
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before, current: after, operations: merge + split))
        XCTAssertThrowsError(try RoomDoorReadback.validate(baseline: before, current: snapshot([3, 99], []), operations: merge))
    }
}
