import XCTest
@testable import FreoCore

private enum PartitionFixture {
    static func integer(_ input: UInt64) -> Data {
        var input = input, data = Data()
        repeat { let part = UInt8(input & 127); input >>= 7; data.append(part | (input == 0 ? 0 : 128)) } while input != 0
        return data
    }
    static func number(_ field: Int, _ value: UInt64) -> Data { integer(UInt64(field << 3)) + integer(value) }
    static func bytes(_ field: Int, _ data: Data) -> Data { integer(UInt64(field << 3 | 2)) + integer(UInt64(data.count)) + data }

    static func floorplan(singleRoom: Bool = false) -> Floorplan {
        let pixels: [UInt32] = (0..<36).map { index in
            let x = index % 6, y = 5 - index / 6, room = singleRoom ? 1 : (x > y ? 1 : 2)
            return 0x10000001 | UInt32(room) << 8
        }
        return Floorplan(mapID: 1, width: 6, height: 6, resolution: 1000,
                         rooms: (singleRoom ? [1] : [1, 2]).map { .init(id: $0, name: "Original \($0)") }, pixels: pixels)
    }

    static func snapshot(_ floorplan: Floorplan, version: UInt32 = 1, limit: Int? = 32,
                         opaque: UInt64 = 77, includeBorder: Bool = true, roomExtra: [Int: Data] = [:]) -> MapSnapshot {
        var raw = number(1, 1) + number(2, 1) + number(3, UInt64(floorplan.resolution ?? 1000)) + number(4, 6) + number(5, 6)
        if includeBorder { raw += bytes(6, number(1, 0) + number(2, 6) + number(3, 0) + number(4, 6)) }
        for room in floorplan.rooms {
            raw += bytes(12, number(1, UInt64(room.id)) + number(2, 0) + bytes(3, Data(room.name.utf8)) + (roomExtra[room.id] ?? Data()))
        }
        raw += bytes(17, Data([UInt8(truncatingIfNeeded: version)])) + number(33, UInt64(version)) + number(100, opaque)
        return MapSnapshot(productKey: "EHf6cRNRGT", deviceID: String(repeating: "a", count: 32), mapID: 1,
                           mapVersion: 1, editVersion: version, capturedAt: Date(), floorplan: floorplan,
                           staticMapPayload: raw, maximumRoomCount: limit)
    }

    static func relabel(_ original: Floorplan, regions: [Set<Int>], ids: [Int], finalNames: Bool = false) -> Floorplan {
        var pixels = original.pixels
        for (cells, id) in zip(regions, ids) {
            for cell in cells { pixels[cell] = (pixels[cell] & ~0xff00) | UInt32(id) << 8 }
        }
        let names = finalNames ? ["Kitchen", "Hallway"] : ids.map { "Saved \($0)" }
        return Floorplan(mapID: 1, width: 6, height: 6, resolution: 1000,
                         rooms: zip(ids, names).map { RobotRoom(id: $0.0, name: $0.1) }, pixels: pixels)
    }

    static func scenario(singleRoom: Bool = false) throws -> (RoomPartitionPlan, [MapSnapshot]) {
        let original = floorplan(singleRoom: singleRoom)
        let plan = try RoomPartitionPlanner.make(floorplan: original, sourceRoomIDs: singleRoom ? [1] : [1, 2],
             rectangle: .init(minX: 3, minY: 2, maxXExclusive: 6, maxYExclusive: 6))
        var states = [snapshot(original)]
        if !singleRoom { states.append(snapshot(relabel(original, regions: [plan.sourceCells], ids: [7]), version: 2)) }
        func append(_ regions: [Set<Int>], _ ids: [Int], finalNames: Bool = false) {
            states.append(snapshot(relabel(original, regions: regions, ids: ids, finalNames: finalNames), version: UInt32(states.count + 1)))
        }
        append([plan.horizontalRemainderCells, plan.cornerBandCells], [7, 11])
        append([plan.horizontalRemainderCells, plan.sideRemainderCells, plan.kitchenCells], [7, 11, 19])
        append([plan.kitchenCells, plan.hallwayCells], [19, 7])
        append([plan.kitchenCells, plan.hallwayCells], [19, 7], finalNames: true)
        return (plan, states)
    }
}

private actor PartitionScenario {
    var states: [MapSnapshot]
    var position = 0
    var reads = 0
    var calls: [[RoomMapOperation]] = []
    let failAt: Int?
    let staleAtRead: Int?
    let acknowledged: Bool
    init(states: [MapSnapshot], failAt: Int? = nil, staleAtRead: Int? = nil, acknowledged: Bool = true) {
        self.states = states; self.failAt = failAt; self.staleAtRead = staleAtRead; self.acknowledged = acknowledged
    }
    func read() -> MapSnapshot {
        reads += 1
        let current = states[position]
        if reads == staleAtRead {
            return PartitionFixture.snapshot(current.floorplan, version: current.editVersion + 100)
        }
        return current
    }
    func apply(_ baseline: MapSnapshot, _ operations: [RoomMapOperation]) throws -> MapEditCommitResult {
        calls.append(operations)
        if calls.count == failAt { throw ConnectorError.outcomeUnknown }
        guard baseline.editVersion == states[position].editVersion else { throw MapEditError.staleSnapshot }
        position += 1
        return MapEditCommitResult(acknowledged: acknowledged, snapshot: states[position],
                                   preservedSnapshotURL: URL(fileURLWithPath: "/private/tmp/synthetic-map-test.bin"))
    }
    func counts() -> (reads: Int, writes: Int) { (reads, calls.count) }
    func operations() -> [[RoomMapOperation]] { calls }
}

final class RoomPartitionTransactionTests: XCTestCase {
    func testDrawnBoxContinuesFromSavedHorizontalDivider() async throws {
        let (previous, states) = try recoveredScenario(from: 2)
        let baseline = states[0]
        let plan = try RoomPartitionPlanner.makeBox(floorplan: baseline.floorplan,
            sourceRoomIDs: previous.sourceRoomIDs, rectangle: previous.rectangle)
        let fake = PartitionScenario(states: states)
        let saved = try await run(plan, baseline: baseline, scenario: fake, resumeOnly: true)
        XCTAssertEqual(saved.floorplan.rooms.map(\.name), ["Kitchen", "Hallway"])
        let operations = await fake.operations()
        XCTAssertEqual(operations.count, 3)
        guard operations.count == 3,
              case .split = operations[0][0],
              case .merge = operations[1][0],
              case .rename = operations[2][0] else {
            return XCTFail("Expected one split, one merge and the names")
        }
    }

    func testDrawnBoxContinuesThroughBoundedFirmwareEdgeCleanup() async throws {
        let (previous, originals) = try recoveredScenario(from: 2)
        let baseline = originals[0]
        let plan = try RoomPartitionPlanner.makeBox(floorplan: baseline.floorplan,
            sourceRoomIDs: previous.sourceRoomIDs, rectangle: previous.rectangle)
        let states = originals.enumerated().map { index, snapshot -> MapSnapshot in
            guard index > 0 else { return snapshot }
            var pixels = snapshot.floorplan.pixels
            pixels[0] = 0x10000020
            let map = Floorplan(mapID: snapshot.floorplan.mapID, width: 6, height: 6,
                resolution: snapshot.floorplan.resolution, rooms: snapshot.floorplan.rooms, pixels: pixels)
            return PartitionFixture.snapshot(map, version: snapshot.editVersion)
        }
        let scenario = PartitionScenario(states: states)
        let saved = try await run(plan, baseline: baseline, scenario: scenario, resumeOnly: true)
        XCTAssertEqual(saved.floorplan.rooms.map(\.name), ["Kitchen", "Hallway"])
        XCTAssertEqual(saved.floorplan.pixels[0], 0x10000020)
        let operations = await scenario.operations()
        XCTAssertEqual(operations.count, 3, "Continue to merge and rename after the first verified divider")
    }

    private func recoveredScenario(from index: Int, limit: Int = 32,
                                   remap: [Int: Int] = [:]) throws -> (RoomPartitionPlan, [MapSnapshot]) {
        let (_, originals) = try PartitionFixture.scenario()
        let states = originals[index...].map { snapshot -> MapSnapshot in
            let source = snapshot.floorplan
            let pixels = source.pixels.map { raw -> UInt32 in
                guard let id = remap[MapPixel(rawValue: raw).roomID] else { return raw }
                return (raw & ~0xff00) | UInt32(id) << 8
            }
            let floorplan = Floorplan(mapID: source.mapID, width: source.width, height: source.height,
                resolution: source.resolution, rooms: source.rooms.map { .init(id: remap[$0.id] ?? $0.id, name: $0.name) }, pixels: pixels)
            return PartitionFixture.snapshot(floorplan, version: snapshot.editVersion, limit: limit)
        }
        let floorplan = states[0].floorplan
        let plan = try RoomPartitionPlanner.make(floorplan: floorplan, sourceRoomIDs: Set(floorplan.rooms.map(\.id)),
            rectangle: .init(minX: 3, minY: 2, maxXExclusive: 6, maxYExclusive: 6))
        return (plan, states)
    }

    private func run(_ plan: RoomPartitionPlan, baseline: MapSnapshot, scenario: PartitionScenario,
                     kitchenName: String = "Kitchen", resumeOnly: Bool = false,
                     preserveReadback: @escaping @Sendable (MapSnapshot) throws -> Void = { _ in }) async throws -> MapSnapshot {
        try await RoomPartitionTransaction.commit(plan: plan, baseline: baseline, kitchenName: kitchenName,
            hallwayName: "Hallway", resumeOnly: resumeOnly, read: { await scenario.read() },
            apply: { try await scenario.apply($0, $1) }, preserveReadback: preserveReadback, progress: { _ in })
    }

    func testFiveSequentialWritesRediscoverIDsAndVerifyFinalNames() async throws {
        let (plan, states) = try PartitionFixture.scenario()
        let fake = PartitionScenario(states: states)
        let saved = try await run(plan, baseline: states[0], scenario: fake)
        XCTAssertEqual(saved.floorplan.rooms.map(\.name), ["Kitchen", "Hallway"])
        XCTAssertEqual(try plan.validateFinalPartition(saved.floorplan), [19, 7])
        let count = await fake.counts(), calls = await fake.operations()
        XCTAssertEqual(count.writes, 5)
        XCTAssertEqual(count.reads, 6)
        if case .split(_, _, let old, let new) = calls[1][0] {
            XCTAssertEqual(old, 7); XCTAssertEqual(new, 8)
        } else { XCTFail("Expected horizontal split") }
        if case .split(_, _, let old, let new) = calls[2][0] {
            XCTAssertEqual(old, 11); XCTAssertEqual(new, 12)
        } else { XCTFail("Expected vertical split") }
        if case .merge(let first, let second, let result) = calls[3][0] {
            XCTAssertEqual(first, 7); XCTAssertEqual(second, 11); XCTAssertEqual(result, 7)
        } else { XCTFail("Expected Hallway merge") }
        XCTAssertEqual(calls[4].count, 2)
    }

    func testAlreadyMergedSourceSkipsInitialMerge() async throws {
        let (plan, states) = try PartitionFixture.scenario(singleRoom: true)
        let fake = PartitionScenario(states: states)
        _ = try await run(plan, baseline: states[0], scenario: fake)
        let count = await fake.counts()
        XCTAssertEqual(count.writes, 4)
    }

    func testFreshHorizontalPartitionStartsWithVerticalCutThenMergeAndNames() async throws {
        let (plan, states) = try recoveredScenario(from: 2)
        XCTAssertEqual(try RoomPartitionTransaction.remainingStage(plan: plan, floorplan: states[0].floorplan), .horizontalDividerSaved)
        let fake = PartitionScenario(states: states)
        let saved = try await run(plan, baseline: states[0], scenario: fake, resumeOnly: true)
        let calls = await fake.operations(), count = await fake.counts()
        XCTAssertEqual(count.writes, 3); XCTAssertEqual(count.reads, 4)
        let points = try MapEditCoordinates(snapshot: states[0])
        if case .split(let start, let end, let oldID, let newID) = calls[0][0] {
            XCTAssertEqual(start, try points.point(plan.verticalCut.start))
            XCTAssertEqual(end, try points.point(plan.verticalCut.end))
            XCTAssertEqual(oldID, 11); XCTAssertEqual(newID, 12)
        } else { XCTFail("Recovery must begin with the remaining vertical divider") }
        if case .merge = calls[1][0] {} else { XCTFail("Expected Hallway merge") }
        XCTAssertEqual(calls[2].count, 2)
        XCTAssertEqual(try plan.validateFinalPartition(saved.floorplan), [19, 7])
    }

    func testFreshThreePiecePartitionOnlyMergesHallwayAndRenames() async throws {
        let (plan, states) = try recoveredScenario(from: 3, limit: 3, remap: [7: 254, 11: 253, 19: 255])
        XCTAssertEqual(try RoomPartitionTransaction.remainingStage(plan: plan, floorplan: states[0].floorplan), .threePiecesSaved)
        let fake = PartitionScenario(states: states)
        _ = try await run(plan, baseline: states[0], scenario: fake, resumeOnly: true)
        let calls = await fake.operations(), count = await fake.counts()
        XCTAssertEqual(count.writes, 2)
        if case .merge(let first, let second, let merged) = calls[0][0] {
            XCTAssertEqual(first, 254); XCTAssertEqual(second, 253); XCTAssertEqual(merged, 254)
        } else { XCTFail("No divider or source-wide merge may repeat") }
        XCTAssertEqual(calls[1].count, 2)
    }

    func testFreshFinalPartitionOnlyRenamesWithoutRequiringSpareRoomSlotOrID() async throws {
        let (plan, states) = try recoveredScenario(from: 4, limit: 2, remap: [7: 254, 19: 255])
        XCTAssertEqual(try RoomPartitionTransaction.remainingStage(plan: plan, floorplan: states[0].floorplan), .finalPartitionSaved)
        let fake = PartitionScenario(states: states)
        let saved = try await run(plan, baseline: states[0], scenario: fake, resumeOnly: true)
        let calls = await fake.operations(), count = await fake.counts()
        XCTAssertEqual(count.writes, 1); XCTAssertEqual(calls[0].count, 2)
        for operation in calls[0] {
            if case .rename = operation {} else { XCTFail("Final geometry must remain untouched") }
        }
        XCTAssertEqual(saved.floorplan.rooms.map(\.name), ["Kitchen", "Hallway"])
    }

    func testFreshFinalPartitionWithCorrectNamesOnlyVerifiesWithoutWriting() async throws {
        let (plan, states) = try recoveredScenario(from: 5, limit: 2, remap: [7: 254, 19: 255])
        let fake = PartitionScenario(states: states)
        let saved = try await run(plan, baseline: states[0], scenario: fake)
        XCTAssertEqual(saved.staticMapPayload, states[0].staticMapPayload)
        let counts = await fake.counts()
        XCTAssertEqual(counts.reads, 1); XCTAssertEqual(counts.writes, 0)
    }

    private func finalNamingRecovery(unreachable: Bool = true) throws -> (RoomPartitionPlan, [MapSnapshot]) {
        let (_, original) = try recoveredScenario(from: 4)
        // A synthetic boundary cell inside the desired rectangle already belongs
        // to Hallway in this newly reviewed baseline. No private map fixture.
        let states = original.map { snapshot -> MapSnapshot in
            let map = snapshot.floorplan
            var pixels = map.pixels
            pixels[3] = (pixels[3] & ~0xffff) | UInt32(7 << 8) | (unreachable ? 0x18 : 0x08)
            let saved = Floorplan(mapID: map.mapID, width: map.width, height: map.height,
                resolution: map.resolution, rooms: map.rooms, pixels: pixels)
            return PartitionFixture.snapshot(saved, version: snapshot.editVersion)
        }
        let plan = try RoomPartitionPlanner.make(floorplan: states[0].floorplan, sourceRoomIDs: [7, 19],
            rectangle: .init(minX: 3, minY: 2, maxXExclusive: 6, maxYExclusive: 6))
        return (plan, states)
    }

    func testSavedUnreachableLabelExceptionOnlyRenamesAndPreservesActualFootprints() async throws {
        let (plan, states) = try finalNamingRecovery()
        XCTAssertThrowsError(try plan.validateFinalPartition(states[0].floorplan))
        XCTAssertEqual(try plan.recognizedFinalPartition(states[0].floorplan), [19, 7])
        XCTAssertEqual(try RoomPartitionTransaction.remainingStage(plan: plan, floorplan: states[0].floorplan), .finalPartitionSaved)
        let fake = PartitionScenario(states: states)
        let saved = try await run(plan, baseline: states[0], scenario: fake, resumeOnly: true)
        XCTAssertEqual(saved.floorplan.pixels, states[0].floorplan.pixels)
        XCTAssertEqual(MapPixel(rawValue: saved.floorplan.pixels[3]).roomID, 7)
        XCTAssertThrowsError(try plan.validateFinalPartition(saved.floorplan), "Naming does not prove a solid all-cell rectangle")
        let calls = await fake.operations()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].count, 2)
        for operation in calls[0] {
            if case .rename = operation {} else { XCTFail("Naming recovery must never split or merge") }
        }
    }

    func testReachableLabelMismatchCannotBecomeNamingRecovery() async throws {
        let (plan, states) = try finalNamingRecovery(unreachable: false)
        XCTAssertThrowsError(try plan.recognizedFinalPartition(states[0].floorplan))
        let fake = PartitionScenario(states: states)
        do { _ = try await run(plan, baseline: states[0], scenario: fake, resumeOnly: true); XCTFail("Reachable labels must match") }
        catch { XCTAssertFalse(error is RoomPartitionTransactionError) }
        let counts = await fake.counts()
        XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.writes, 0)
    }

    func testNamingRecoveryRejectsEveryPixelMutationIncludingUnreachableRelabel() async throws {
        let (plan, originals) = try finalNamingRecovery()
        for changedBits: UInt32 in [0x10, 0x08, 0x10000000, UInt32((7 ^ 19) << 8)] {
            var states = originals
            let map = states[1].floorplan
            var pixels = map.pixels; pixels[3] ^= changedBits
            let changed = Floorplan(mapID: map.mapID, width: map.width, height: map.height,
                resolution: map.resolution, rooms: map.rooms, pixels: pixels)
            states[1] = PartitionFixture.snapshot(changed, version: states[1].editVersion)
            let fake = PartitionScenario(states: states)
            do { _ = try await run(plan, baseline: states[0], scenario: fake, resumeOnly: true); XCTFail("A rename cannot mutate pixels") }
            catch let error as RoomPartitionTransactionError { XCTAssertEqual(error.completedSteps, 0) }
            let counts = await fake.counts()
            XCTAssertEqual(counts.writes, 1)
        }
    }

    func testNamingRecognitionCannotAcceptANewerOrChangedRasterAsBaseline() throws {
        let (plan, states) = try finalNamingRecovery()
        let map = states[0].floorplan
        var pixels = map.pixels
        pixels[3] = (pixels[3] & ~0xff00) | UInt32(19 << 8)
        let changed = Floorplan(mapID: map.mapID, width: map.width, height: map.height,
            resolution: map.resolution, rooms: map.rooms, pixels: pixels)
        XCTAssertThrowsError(try plan.recognizedFinalPartition(changed))
    }

    func testNamingRecognitionNeedsNonUnreachableEvidenceForBothRooms() throws {
        let (_, states) = try finalNamingRecovery()
        let map = states[0].floorplan
        let pixels = map.pixels.map { raw in MapPixel(rawValue: raw).roomID == 19 ? raw | 0x10 : raw }
        let changed = Floorplan(mapID: map.mapID, width: map.width, height: map.height,
            resolution: map.resolution, rooms: map.rooms, pixels: pixels)
        let plan = try RoomPartitionPlanner.make(floorplan: changed, sourceRoomIDs: [7, 19],
            rectangle: .init(minX: 3, minY: 2, maxXExclusive: 6, maxYExclusive: 6))
        XCTAssertThrowsError(try plan.recognizedFinalPartition(changed))
    }

    func testNamingRecoveryPreservesUnknownSelectedRoomMetadata() async throws {
        let (plan, original) = try finalNamingRecovery()
        for altered in [false, true] {
            let baseline = PartitionFixture.snapshot(original[0].floorplan, version: original[0].editVersion,
                roomExtra: [19: PartitionFixture.number(50, 123)])
            let after = PartitionFixture.snapshot(original[1].floorplan, version: original[1].editVersion,
                roomExtra: [19: PartitionFixture.number(50, altered ? 124 : 123)])
            let fake = PartitionScenario(states: [baseline, after])
            do {
                _ = try await run(plan, baseline: baseline, scenario: fake, resumeOnly: true)
                XCTAssertFalse(altered)
            } catch {
                XCTAssertTrue(altered)
                XCTAssertTrue(error is RoomPartitionTransactionError)
            }
            let counts = await fake.counts()
            XCTAssertEqual(counts.writes, 1)
        }
    }

    func testHorizontalRecoveryRequiresOnlyOneIdentifierButStillOneExtraRoomSlot() async throws {
        for limit in [2, 3] {
            let (plan, states) = try recoveredScenario(from: 2, limit: limit, remap: [7: 254, 11: 253, 19: 255])
            let fake = PartitionScenario(states: states)
            do {
                _ = try await run(plan, baseline: states[0], scenario: fake)
                XCTAssertEqual(limit, 3)
            } catch {
                XCTAssertEqual(limit, 2)
                XCTAssertFalse(error is RoomPartitionTransactionError)
            }
            let counts = await fake.counts()
            XCTAssertEqual(counts.writes, limit == 3 ? 3 : 0)
        }
    }

    func testArbitraryThreeRoomSelectionIsRejectedBeforeAnyReadOrWrite() async throws {
        let pixels = (0..<36).map { UInt32($0 % 6 / 2 + 1) << 8 | 0x10000001 }
        let floorplan = Floorplan(mapID: 1, width: 6, height: 6, resolution: 1000,
            rooms: (1...3).map { .init(id: $0, name: "Room \($0)") }, pixels: pixels)
        let baseline = PartitionFixture.snapshot(floorplan)
        let plan = try RoomPartitionPlanner.make(floorplan: floorplan, sourceRoomIDs: [1, 2, 3],
            rectangle: .init(minX: 3, minY: 2, maxXExclusive: 6, maxYExclusive: 6))
        XCTAssertThrowsError(try RoomPartitionTransaction.remainingStage(plan: plan, floorplan: floorplan))
        let fake = PartitionScenario(states: [baseline])
        do { _ = try await run(plan, baseline: baseline, scenario: fake); XCTFail("No automatic merge for arbitrary triples") }
        catch { XCTAssertFalse(error is RoomPartitionTransactionError) }
        let counts = await fake.counts()
        XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.writes, 0)
    }

    func testExplicitResumeNeverFallsBackToWholeAreaMergeOrNewCuts() async throws {
        for singleRoom in [false, true] {
            let (plan, states) = try PartitionFixture.scenario(singleRoom: singleRoom)
            XCTAssertEqual(try RoomPartitionTransaction.remainingStage(plan: plan, floorplan: states[0].floorplan), .wholeArea)
            let fake = PartitionScenario(states: states)
            do {
                _ = try await run(plan, baseline: states[0], scenario: fake, resumeOnly: true)
                XCTFail("Explicit recovery must not silently restart geometry edits")
            } catch { XCTAssertFalse(error is RoomPartitionTransactionError) }
            let counts = await fake.counts()
            XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.writes, 0)
        }
    }

    func testRecoveredBaselineStillRejectsStaleReadsBeforeFirstWrite() async throws {
        for stage in [2, 3, 4] {
            let (plan, states) = try recoveredScenario(from: stage)
            let fake = PartitionScenario(states: states, staleAtRead: 1)
            do { _ = try await run(plan, baseline: states[0], scenario: fake); XCTFail("Recovery requires the newly reviewed exact baseline") }
            catch { XCTAssertFalse(error is RoomPartitionTransactionError) }
            let count = await fake.counts()
            XCTAssertEqual(count.writes, 0)
        }
    }

    func testRecoveredWriteNormalizationStillStopsWithoutRetryOrNextOperation() async throws {
        let (plan, original) = try recoveredScenario(from: 2)
        var states = original
        let source = states[1].floorplan
        var pixels = source.pixels; pixels[0] ^= 0x10
        let changed = Floorplan(mapID: source.mapID, width: source.width, height: source.height,
            resolution: source.resolution, rooms: source.rooms, pixels: pixels)
        states[1] = PartitionFixture.snapshot(changed, version: states[1].editVersion)
        let fake = PartitionScenario(states: states)
        do { _ = try await run(plan, baseline: states[0], scenario: fake); XCTFail("Recovery must not tolerate structural normalization") }
        catch let error as RoomPartitionTransactionError { XCTAssertEqual(error.completedSteps, 0) }
        let counts = await fake.counts()
        XCTAssertEqual(counts.writes, 1)
    }

    func testUnknownAcknowledgementCanProceedOnlyWithExactVerifiedReadback() async throws {
        let (plan, states) = try PartitionFixture.scenario()
        let fake = PartitionScenario(states: states, acknowledged: false)
        _ = try await run(plan, baseline: states[0], scenario: fake)
        let count = await fake.counts()
        XCTAssertEqual(count.writes, 5)
    }

    func testPredictableNameCapacityAndCoordinateErrorsSendNothing() async throws {
        let (plan, states) = try PartitionFixture.scenario()
        let invalid = [
            PartitionFixture.snapshot(states[0].floorplan, limit: nil),
            PartitionFixture.snapshot(states[0].floorplan, limit: 2),
            PartitionFixture.snapshot(states[0].floorplan, includeBorder: false),
        ]
        for baseline in invalid {
            let fake = PartitionScenario(states: [baseline])
            do { _ = try await run(plan, baseline: baseline, scenario: fake); XCTFail("Expected preflight failure") }
            catch { XCTAssertFalse(error is RoomPartitionTransactionError) }
            let count = await fake.counts()
            XCTAssertEqual(count.writes, 0)
        }
        let fake = PartitionScenario(states: states)
        do { _ = try await run(plan, baseline: states[0], scenario: fake, kitchenName: "\n"); XCTFail("Expected name failure") }
        catch { XCTAssertFalse(error is RoomPartitionTransactionError) }
        let count = await fake.counts()
        XCTAssertEqual(count.writes, 0)
    }

    func testUncertainWriteStopsWithoutRetryAndReportsPossiblePartialSave() async throws {
        let (plan, states) = try PartitionFixture.scenario()
        let fake = PartitionScenario(states: states, failAt: 2)
        do { _ = try await run(plan, baseline: states[0], scenario: fake); XCTFail("Expected failure") }
        catch let error as RoomPartitionTransactionError {
            XCTAssertTrue(error.mayHaveChanged)
            XCTAssertEqual(error.completedSteps, 1)
        }
        let count = await fake.counts()
        XCTAssertEqual(count.writes, 2)
    }

    func testStaleInitialMapStopsBeforeAnyWriteAndMidwayStalenessStopsFurtherWrites() async throws {
        let (plan, states) = try PartitionFixture.scenario()
        for staleAtRead in [1, 3] {
            let fake = PartitionScenario(states: states, staleAtRead: staleAtRead)
            do { _ = try await run(plan, baseline: states[0], scenario: fake); XCTFail("Expected stale-map failure") }
            catch { XCTAssertEqual(error is RoomPartitionTransactionError, staleAtRead == 3) }
            let count = await fake.counts()
            XCTAssertEqual(count.writes, staleAtRead == 1 ? 0 : 1)
        }
    }

    func testChangedOpaqueMapMetadataStopsAfterFirstWrite() async throws {
        let (plan, originals) = try PartitionFixture.scenario()
        var states = originals
        states[1] = PartitionFixture.snapshot(states[1].floorplan, version: 2, opaque: 88)
        let fake = PartitionScenario(states: states)
        do { _ = try await run(plan, baseline: states[0], scenario: fake); XCTFail("Expected metadata failure") }
        catch { XCTAssertTrue(error is RoomPartitionTransactionError) }
        let count = await fake.counts()
        XCTAssertEqual(count.writes, 1)
    }

    func testRejectedMetadataReadbackRemainsOnDiskAndStopsNextWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plan, originals) = try PartitionFixture.scenario()
        var states = originals
        states[1] = PartitionFixture.snapshot(states[1].floorplan, version: 2, opaque: 88)
        let fake = PartitionScenario(states: states)
        do {
            _ = try await run(plan, baseline: states[0], scenario: fake, preserveReadback: {
                _ = try MapSnapshotStore.preserveReadback($0, directory: directory)
            })
            XCTFail("Unexpected metadata must still stop the transaction")
        } catch let error as RoomPartitionTransactionError {
            XCTAssertEqual(error.completedSteps, 0)
            XCTAssertTrue(error.detail.contains("metadata"))
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: Any])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(object["staticMapPayload"] as? String)), states[1].staticMapPayload)
        let counts = await fake.counts()
        XCTAssertEqual(counts.writes, 1)
    }

    func testReadbackStorageFailureStopsFurtherPartitionWrites() async throws {
        let (plan, states) = try PartitionFixture.scenario()
        let fake = PartitionScenario(states: states)
        do {
            _ = try await run(plan, baseline: states[0], scenario: fake, preserveReadback: { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
            XCTFail("Cannot continue without preserving the post-write readback")
        } catch let error as RoomPartitionTransactionError {
            XCTAssertEqual(error.completedSteps, 0)
        }
        let counts = await fake.counts()
        XCTAssertEqual(counts.writes, 1)
    }

    func testUnselectedRoomMetadataIsComparedWithOriginalBaseline() async throws {
        let (_, originals) = try PartitionFixture.scenario()
        let states = originals.enumerated().map { index, snapshot -> MapSnapshot in
            let original = snapshot.floorplan
            let rooms = original.rooms + [RobotRoom(id: 99, name: index == 0 ? "Unchanged room" : "Unexpected rename")]
            let floorplan = Floorplan(mapID: 1, width: 6, height: 6, resolution: 1000, rooms: rooms, pixels: original.pixels)
            return PartitionFixture.snapshot(floorplan, version: snapshot.editVersion)
        }
        let plan = try RoomPartitionPlanner.make(floorplan: states[0].floorplan, sourceRoomIDs: [1, 2],
             rectangle: .init(minX: 3, minY: 2, maxXExclusive: 6, maxYExclusive: 6))
        let fake = PartitionScenario(states: states)
        do { _ = try await run(plan, baseline: states[0], scenario: fake); XCTFail("Expected unrelated metadata failure") }
        catch { XCTAssertTrue(error is RoomPartitionTransactionError) }
        let count = await fake.counts()
        XCTAssertEqual(count.writes, 1)
    }

    func testInsufficientEightBitIdentifiersFailBeforeFirstMutation() async throws {
        let original = PartitionFixture.floorplan()
        let pixels = original.pixels.map { raw in
            MapPixel(rawValue: raw).roomID == 1 ? (raw & ~0xff00) | 254 << 8 : raw
        }
        let floorplan = Floorplan(mapID: 1, width: 6, height: 6, resolution: 1000,
                                 rooms: [.init(id: 254, name: "First"), .init(id: 2, name: "Second")], pixels: pixels)
        let baseline = PartitionFixture.snapshot(floorplan)
        let plan = try RoomPartitionPlanner.make(floorplan: floorplan, sourceRoomIDs: [254, 2],
             rectangle: .init(minX: 3, minY: 2, maxXExclusive: 6, maxYExclusive: 6))
        let fake = PartitionScenario(states: [baseline])
        do { _ = try await run(plan, baseline: baseline, scenario: fake); XCTFail("Expected identifier-capacity failure") }
        catch { XCTAssertFalse(error is RoomPartitionTransactionError) }
        let count = await fake.counts()
        XCTAssertEqual(count.writes, 0)
    }

    func testWrongReadbackGeometryStopsBeforeNextCommand() async throws {
        let (plan, originals) = try PartitionFixture.scenario()
        var states = originals
        // A newer response that still contains a single merged region is not a
        // successful horizontal split, regardless of the accepted acknowledgement.
        states[2] = PartitionFixture.snapshot(states[1].floorplan, version: 3)
        let fake = PartitionScenario(states: states)
        do { _ = try await run(plan, baseline: states[0], scenario: fake); XCTFail("Expected geometry failure") }
        catch { XCTAssertTrue(error is RoomPartitionTransactionError) }
        let count = await fake.counts()
        XCTAssertEqual(count.writes, 2)
    }

    func testFinalNameMismatchIsNotReportedAsSuccess() async throws {
        let (plan, originals) = try PartitionFixture.scenario()
        var states = originals
        states[5] = PartitionFixture.snapshot(states[4].floorplan, version: 6)
        let fake = PartitionScenario(states: states)
        do { _ = try await run(plan, baseline: states[0], scenario: fake); XCTFail("Expected naming failure") }
        catch { XCTAssertTrue(error is RoomPartitionTransactionError) }
        let count = await fake.counts()
        XCTAssertEqual(count.writes, 5)
    }
}
