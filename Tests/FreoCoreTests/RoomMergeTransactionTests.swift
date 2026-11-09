import XCTest
@testable import FreoCore

private enum MergeFixture {
    static func integer(_ input: UInt64) -> Data {
        var value = input, data = Data()
        repeat { let part = UInt8(value & 127); value >>= 7; data.append(part | (value == 0 ? 0 : 128)) } while value != 0
        return data
    }
    static func number(_ field: Int, _ value: UInt64) -> Data { integer(UInt64(field << 3)) + integer(value) }
    static func bytes(_ field: Int, _ value: Data) -> Data { integer(UInt64(field << 3 | 2)) + integer(UInt64(value.count)) + value }
    static func map(pixels: [UInt32] = [0x101,0x101,0x201,0x301, 0x101,0x101,0x201,0x301],
                    rooms: [RobotRoom] = [.init(id: 1, name: "Kitchen"), .init(id: 2, name: "Hallway"), .init(id: 3, name: "Bath")]) -> Floorplan {
        Floorplan(mapID: 4, width: 4, height: 2, resolution: 60, rooms: rooms, pixels: pixels)
    }
    static func snapshot(_ floorplan: Floorplan = map(), revision: UInt32 = 7, opaque: UInt64 = 70,
                         foreignOpaque: UInt64 = 90, productKey: String = "EHf6cRNRGT",
                         deviceID: String = String(repeating: "a", count: 32)) -> MapSnapshot {
        var raw = number(1, 4) + number(2, 1) + number(3, 60) + number(4, 4) + number(5, 2)
        raw += bytes(6, number(1, 0) + number(2, 4) + number(3, 0) + number(4, 2))
        for room in floorplan.rooms {
            raw += bytes(12, number(1, UInt64(room.id)) + number(2, 0) + bytes(3, Data(room.name.utf8))
                         + number(40, room.id == 3 ? foreignOpaque : 90))
        }
        raw += number(33, UInt64(revision)) + number(100, opaque)
        return MapSnapshot(productKey: productKey, deviceID: deviceID, mapID: 4, mapVersion: 1,
            editVersion: revision, capturedAt: Date(), floorplan: floorplan, staticMapPayload: raw, maximumRoomCount: 32)
    }
    static func merged() throws -> Floorplan {
        try RoomMergeTransaction.demoMergedFloorplan(floorplan: map(), sourceRoomIDs: [1,2])
    }
}

private actor MergeScenario {
    let fresh: MapSnapshot
    let saved: MapSnapshot
    let failure: Error?
    var reads = 0
    var operations: [[RoomMapOperation]] = []
    init(fresh: MapSnapshot, saved: MapSnapshot, failure: Error? = nil) {
        self.fresh = fresh; self.saved = saved; self.failure = failure
    }
    func read() -> MapSnapshot { reads += 1; return fresh }
    func apply(_ baseline: MapSnapshot, _ operations: [RoomMapOperation]) throws -> MapEditCommitResult {
        self.operations.append(operations)
        if let failure { throw failure }
        return MapEditCommitResult(acknowledged: true, snapshot: saved,
                                  preservedSnapshotURL: URL(fileURLWithPath: "/private/tmp/synthetic-merge"))
    }
    func counts() -> (Int, Int) { (reads, operations.count) }
    func calls() -> [[RoomMapOperation]] { operations }
}

private final class MergePreservation: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MapSnapshot] = []
    func append(_ value: MapSnapshot) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

final class RoomMergeTransactionTests: XCTestCase {
    private func commit(_ baseline: MapSnapshot, sources: Set<Int> = [1,2], scenario: MergeScenario,
                        preserved: MergePreservation = MergePreservation()) async throws -> MapSnapshot {
        try await RoomMergeTransaction.commit(baseline: baseline, sourceRoomIDs: sources,
            read: { await scenario.read() }, apply: { try await scenario.apply($0, $1) },
            preserveReadback: { preserved.append($0) })
    }

    func testOneMergePreservesSourceUnionForeignRoomAndName() async throws {
        let baseline = MergeFixture.snapshot()
        let saved = MergeFixture.snapshot(try MergeFixture.merged(), revision: 8)
        let scenario = MergeScenario(fresh: baseline, saved: saved), preserved = MergePreservation()
        let result = try await commit(baseline, scenario: scenario, preserved: preserved)
        XCTAssertEqual(result.floorplan.rooms, [.init(id: 1, name: "Kitchen"), .init(id: 3, name: "Bath")])
        XCTAssertEqual(result.floorplan.pixels, [0x101,0x101,0x101,0x301, 0x101,0x101,0x101,0x301])
        let counts = await scenario.counts(), calls = await scenario.calls()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1); XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(calls[0].count, 1)
        if case .merge(let a, let b, let target) = calls[0][0] {
            XCTAssertEqual(a, 1); XCTAssertEqual(b, 2); XCTAssertEqual(target, 1)
        } else { XCTFail("Expected exactly one merge, no split or rename") }
    }

    func testRejectsInvalidSelectionBeforeReadingOrWriting() async throws {
        let baseline = MergeFixture.snapshot(), scenario = MergeScenario(fresh: MergeFixture.snapshot(), saved: MergeFixture.snapshot())
        for sources: Set<Int> in [[], [1], [1,2,3], [1,4], [1,3]] {
            do { _ = try await commit(baseline, sources: sources, scenario: scenario); XCTFail("Invalid selection accepted") } catch { }
        }
        let counts = await scenario.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }

    func testWallsCannotProvideRoomAdjacency() {
        let blocked = MergeFixture.map(pixels: [0x101,0x121,0x201,0x301, 0x101,0x121,0x201,0x301])
        XCTAssertThrowsError(try RoomMergeTransaction.validate(floorplan: blocked, sourceRoomIDs: [1,2]))
    }

    func testDetachedUnreachableIslandIsRetainedExactly() throws {
        let map = Floorplan(mapID: 4, width: 5, height: 2, resolution: 60,
            rooms: [.init(id: 1, name: "Kitchen"), .init(id: 2, name: "Hallway")],
            pixels: [0x101,0x201,0,0,0x110, 0x101,0x201,0,0,0])
        let merged = try RoomMergeTransaction.demoMergedFloorplan(floorplan: map, sourceRoomIDs: [1,2])
        XCTAssertEqual(merged.pixels[4], 0x110)
        XCTAssertEqual(merged.pixels.filter { MapPixel(rawValue: $0).roomID == 1 }.count, 5)
        var disconnected = map.pixels; disconnected[4] = 0x101
        let invalid = Floorplan(mapID: 4, width: 5, height: 2, resolution: 60, rooms: map.rooms, pixels: disconnected)
        XCTAssertThrowsError(try RoomMergeTransaction.validate(floorplan: invalid, sourceRoomIDs: [1,2]))
    }

    func testStaleMapFailsBeforeWrite() async throws {
        let baseline = MergeFixture.snapshot()
        let scenario = MergeScenario(fresh: MergeFixture.snapshot(revision: 8),
                                     saved: MergeFixture.snapshot(try MergeFixture.merged(), revision: 9))
        do { _ = try await commit(baseline, scenario: scenario); XCTFail("Stale map accepted") }
        catch { XCTAssertTrue(error is MapEditError) }
        let counts = await scenario.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0)
    }

    func testStructuralForeignAndIncompleteMergeChangesAreRejectedAfterOneWrite() async throws {
        let baseline = MergeFixture.snapshot(), merged = try MergeFixture.merged()
        var structural = merged.pixels; structural[0] ^= 0x10
        var foreign = merged.pixels; foreign[3] ^= 0x1
        var incomplete = merged.pixels; incomplete[0] = 0x201
        let cases = [structural, foreign, incomplete]
        for pixels in cases {
            let invalid = MergeFixture.map(pixels: pixels, rooms: merged.rooms)
            let scenario = MergeScenario(fresh: baseline, saved: MergeFixture.snapshot(invalid, revision: 8))
            let preserved = MergePreservation()
            do { _ = try await commit(baseline, scenario: scenario, preserved: preserved); XCTFail("Unexpected raster accepted") }
            catch { XCTAssertTrue(error is RoomMergeTransactionError) }
            let counts = await scenario.counts(); XCTAssertEqual(counts.1, 1); XCTAssertEqual(preserved.count, 1)
        }
    }

    func testOpaqueMapAndForeignRoomMetadataRemainProtected() async throws {
        let baseline = MergeFixture.snapshot(), merged = try MergeFixture.merged()
        for saved in [MergeFixture.snapshot(merged, revision: 8, opaque: 71),
                      MergeFixture.snapshot(merged, revision: 8, foreignOpaque: 91)] {
            let scenario = MergeScenario(fresh: baseline, saved: saved), preserved = MergePreservation()
            do { _ = try await commit(baseline, scenario: scenario, preserved: preserved); XCTFail("Metadata change accepted") }
            catch { XCTAssertTrue(error is RoomMergeTransactionError) }
            let counts = await scenario.counts(); XCTAssertEqual(counts.1, 1); XCTAssertEqual(preserved.count, 1)
        }
    }

    func testUnrequestedNamesAndRoomIDCompactionStopVerification() async throws {
        let baseline = MergeFixture.snapshot(), merged = try MergeFixture.merged()
        let renamed = MergeFixture.map(pixels: merged.pixels,
            rooms: [.init(id: 1, name: "Room"), .init(id: 3, name: "Bath")])
        let compacted = MergeFixture.map(pixels: merged.pixels.map { $0 == 0x301 ? 0x201 : $0 },
            rooms: [.init(id: 1, name: "Kitchen"), .init(id: 2, name: "Bath")])
        for map in [renamed, compacted] {
            let scenario = MergeScenario(fresh: baseline, saved: MergeFixture.snapshot(map, revision: 8))
            do { _ = try await commit(baseline, scenario: scenario); XCTFail("Unexpected room catalog accepted") }
            catch { XCTAssertTrue(error is RoomMergeTransactionError) }
            let counts = await scenario.counts(); XCTAssertEqual(counts.1, 1)
        }
    }

    func testIdentityOrRevisionMismatchIsPreservedAndRejected() async throws {
        let baseline = MergeFixture.snapshot(), merged = try MergeFixture.merged()
        let savedMaps = [MergeFixture.snapshot(merged, revision: 7),
                        MergeFixture.snapshot(merged, revision: 8, deviceID: String(repeating: "b", count: 32))]
        for saved in savedMaps {
            let scenario = MergeScenario(fresh: baseline, saved: saved), preserved = MergePreservation()
            do { _ = try await commit(baseline, scenario: scenario, preserved: preserved); XCTFail("Identity/revision mismatch accepted") }
            catch { XCTAssertTrue(error is RoomMergeTransactionError) }
            let counts = await scenario.counts(); XCTAssertEqual(counts.1, 1); XCTAssertEqual(preserved.count, 1)
        }
    }

    func testUnknownOutcomeIsNeverRetried() async throws {
        let baseline = MergeFixture.snapshot()
        let scenario = MergeScenario(fresh: baseline, saved: baseline, failure: ConnectorError.outcomeUnknown)
        do { _ = try await commit(baseline, scenario: scenario); XCTFail("Unknown result accepted") }
        catch { XCTAssertTrue(error is RoomMergeTransactionError) }
        let counts = await scenario.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }

    func testCancellationAfterFreshReadPreventsMutation() async throws {
        let baseline = MergeFixture.snapshot(), scenario = MergeScenario(fresh: MergeFixture.snapshot(), saved: MergeFixture.snapshot())
        let task = Task {
            try await RoomMergeTransaction.commit(baseline: baseline, sourceRoomIDs: [1,2], read: {
                withUnsafeCurrentTask { $0?.cancel() }; return baseline
            }, apply: { try await scenario.apply($0, $1) }, preserveReadback: { _ in })
        }
        do { _ = try await task.value; XCTFail("Cancelled merge accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        let counts = await scenario.counts(); XCTAssertEqual(counts.1, 0)
    }
}
