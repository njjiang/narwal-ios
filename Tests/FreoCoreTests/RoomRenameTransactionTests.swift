import XCTest
@testable import FreoCore

private enum RenameFixture {
    static func integer(_ value: UInt64) -> Data {
        var value = value, data = Data()
        repeat { let part = UInt8(value & 127); value >>= 7; data.append(part | (value == 0 ? 0 : 128)) } while value != 0
        return data
    }
    static func number(_ field: Int, _ value: UInt64) -> Data { integer(UInt64(field << 3)) + integer(value) }
    static func bytes(_ field: Int, _ value: Data) -> Data { integer(UInt64(field << 3 | 2)) + integer(UInt64(value.count)) + value }
    static func snapshot(names: [String] = ["Kitchen", "Hallway"], version: UInt32 = 7,
                         pixels: [UInt32] = [0x101, 0x101, 0x201, 0x201], opaque: UInt64 = 70,
                         roomOpaque: UInt64 = 90) -> MapSnapshot {
        let rooms = names.enumerated().map { RobotRoom(id: $0.offset + 1, name: $0.element) }
        let map = Floorplan(mapID: 4, width: 2, height: 2, resolution: 60, rooms: rooms, pixels: pixels, mapRevision: version)
        var raw = number(1, 4) + number(2, 1) + number(3, 60) + number(4, 2) + number(5, 2)
        raw += bytes(6, number(1, 0) + number(2, 2) + number(3, 0) + number(4, 2))
        for room in rooms {
            raw += bytes(12, number(1, UInt64(room.id)) + number(2, 0) + bytes(3, Data(room.name.utf8)) + number(40, roomOpaque))
        }
        raw += number(33, UInt64(version)) + number(100, opaque)
        return MapSnapshot(productKey: "EHf6cRNRGT", deviceID: String(repeating: "a", count: 32), mapID: 4,
            mapVersion: 1, editVersion: version, capturedAt: Date(), floorplan: map, staticMapPayload: raw)
    }
}

private actor RenameScenario {
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
        return MapEditCommitResult(acknowledged: true, snapshot: saved, preservedSnapshotURL: URL(fileURLWithPath: "/private/tmp/synthetic-rename"))
    }
    func counts() -> (Int, Int) { (reads, operations.count) }
    func calls() -> [[RoomMapOperation]] { operations }
}

final class RoomRenameTransactionTests: XCTestCase {
    private func commit(baseline: MapSnapshot, names: [Int: String], scenario: RenameScenario) async throws -> MapSnapshot {
        try await RoomRenameTransaction.commit(baseline: baseline, names: names,
            read: { await scenario.read() }, apply: { try await scenario.apply($0, $1) }, preserveReadback: { _ in })
    }
    func testOnlyChangedTrimmedNamesAreWrittenAndGeometryIsPreserved() async throws {
        let baseline = RenameFixture.snapshot(), saved = RenameFixture.snapshot(names: ["Entry", "Hallway"], version: 8)
        let fake = RenameScenario(fresh: baseline, saved: saved)
        let result = try await commit(baseline: baseline, names: [1: "  Entry  ", 2: "Hallway"], scenario: fake)
        XCTAssertEqual(result.floorplan.pixels, baseline.floorplan.pixels)
        XCTAssertEqual(result.floorplan.rooms.map(\.name), ["Entry", "Hallway"])
        let counts = await fake.counts(), calls = await fake.calls()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1); XCTAssertEqual(calls[0].count, 1)
        if case .rename(let id, let name) = calls[0][0] { XCTAssertEqual(id, 1); XCTAssertEqual(name, "Entry") }
        else { XCTFail("Names-only save sent a geometry operation") }
    }
    func testUnchangedNamesDoNotReadOrWrite() async throws {
        let baseline = RenameFixture.snapshot(), fake = RenameScenario(fresh: RenameFixture.snapshot(), saved: RenameFixture.snapshot())
        _ = try await commit(baseline: baseline, names: [1: "Kitchen", 2: "Hallway"], scenario: fake)
        let counts = await fake.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }
    func testRejectsInvalidDuplicateAndUnknownNamesBeforeAnyRequest() async throws {
        let baseline = RenameFixture.snapshot(), fake = RenameScenario(fresh: RenameFixture.snapshot(), saved: RenameFixture.snapshot())
        for names in [[1: "  "], [1: "hÁllway"], [3: "Entry"], [1: "bad\nname"], [1: String(repeating: "a", count: 65)]] {
            do { _ = try await commit(baseline: baseline, names: names, scenario: fake); XCTFail("Invalid names accepted") } catch { }
        }
        let counts = await fake.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }
    func testPreexistingDuplicatesDoNotPreventUnrelatedRename() throws {
        let map = RenameFixture.snapshot(names: ["Room", "Room", "Kitchen"]).floorplan
        XCTAssertEqual(try RoomRenameTransaction.changedNames(in: map, requested: [3: "Entry"]), [3: "Entry"])
        XCTAssertThrowsError(try RoomRenameTransaction.changedNames(in: map, requested: [3: "room"]))
    }
    func testChangedRevisionFailsBeforeWrite() async throws {
        let baseline = RenameFixture.snapshot(), fake = RenameScenario(fresh: RenameFixture.snapshot(version: 8), saved: RenameFixture.snapshot(version: 9))
        do { _ = try await commit(baseline: baseline, names: [1: "Entry"], scenario: fake); XCTFail("Stale map accepted") }
        catch { XCTAssertTrue(error is MapEditError) }
        let counts = await fake.counts(); XCTAssertEqual(counts.1, 0)
    }
    func testRejectsPixelMetadataAndUnrequestedNameChangesAfterOneWrite() async throws {
        let baseline = RenameFixture.snapshot()
        let invalid = [
            RenameFixture.snapshot(names: ["Entry", "Hallway"], version: 8, pixels: [0x201, 0x101, 0x201, 0x201]),
            RenameFixture.snapshot(names: ["Entry", "Hallway"], version: 8, opaque: 71),
            RenameFixture.snapshot(names: ["Entry", "Hallway"], version: 8, roomOpaque: 91),
            RenameFixture.snapshot(names: ["Entry", "Other"], version: 8),
            RenameFixture.snapshot(names: ["Entry", "Hallway"], version: 7)
        ]
        for saved in invalid {
            let fake = RenameScenario(fresh: baseline, saved: saved)
            do { _ = try await commit(baseline: baseline, names: [1: "Entry"], scenario: fake); XCTFail("Unverified save accepted") }
            catch { XCTAssertTrue(error is RoomRenameTransactionError) }
            let counts = await fake.counts(); XCTAssertEqual(counts.1, 1)
        }
    }
    func testUnknownOutcomeIsNeverRetried() async throws {
        let baseline = RenameFixture.snapshot(), fake = RenameScenario(fresh: RenameFixture.snapshot(), saved: RenameFixture.snapshot(), failure: ConnectorError.outcomeUnknown)
        do { _ = try await commit(baseline: baseline, names: [1: "Entry"], scenario: fake); XCTFail("Unknown outcome accepted") }
        catch { XCTAssertTrue(error is RoomRenameTransactionError) }
        let counts = await fake.counts(); XCTAssertEqual(counts.1, 1)
    }
    func testCancellationAfterFreshReadPreventsWrite() async throws {
        let baseline = RenameFixture.snapshot(), fake = RenameScenario(fresh: RenameFixture.snapshot(), saved: RenameFixture.snapshot())
        let task = Task {
            try await RoomRenameTransaction.commit(baseline: baseline, names: [1: "Entry"], read: {
                withUnsafeCurrentTask { $0?.cancel() }
                return baseline
            }, apply: { try await fake.apply($0, $1) }, preserveReadback: { _ in })
        }
        do { _ = try await task.value; XCTFail("Cancelled edit accepted") } catch { XCTAssertTrue(error is CancellationError) }
        let counts = await fake.counts(); XCTAssertEqual(counts.1, 0)
    }
}
