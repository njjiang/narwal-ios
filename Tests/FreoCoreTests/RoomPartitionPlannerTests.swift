import XCTest
@testable import FreoCore

final class RoomPartitionPlannerTests: XCTestCase {
    func testInteriorBoxPlansFourCutsAndJoinsTheRemainder() throws {
        let floorplan = replacing(map(room: { _, _ in 1 }), resolution: 1000)
        let plan = try RoomPartitionPlanner.makeBox(floorplan: floorplan, sourceRoomIDs: [1],
            rectangle: .init(minX: 2, minY: 2, maxXExclusive: 4, maxYExclusive: 4))
        let steps = try XCTUnwrap(plan.boxSteps)
        XCTAssertEqual(steps.count, 7)
        XCTAssertEqual(steps.map { $0.regions.count }, [2, 3, 4, 5, 4, 3, 2])
        XCTAssertEqual(Set(try XCTUnwrap(steps.last).regions), [plan.kitchenCells, plan.hallwayCells])
    }

    func testCornerCropPlansOneRectangleAndOneMergedRemainder() throws {
        let floorplan = replacing(map(room: { _, _ in 1 }), resolution: 1000)
        let plan = try RoomPartitionPlanner.makeBox(floorplan: floorplan, sourceRoomIDs: [1],
            rectangle: .init(minX: 0, minY: 0, maxXExclusive: 2, maxYExclusive: 2))
        let steps = try XCTUnwrap(plan.boxSteps)
        XCTAssertEqual(steps.filter { if case .split = $0.operation { true } else { false } }.count, 2)
        XCTAssertEqual(steps.filter { if case .merge = $0.operation { true } else { false } }.count, 1)
        XCTAssertEqual(steps.last?.regions.count, 2)
        XCTAssertEqual(Set(try XCTUnwrap(steps.last).regions), [plan.kitchenCells, plan.hallwayCells])
        XCTAssertEqual(plan.kitchenCells.count, 4)
        XCTAssertEqual(plan.hallwayCells.count, 32)
        XCTAssertTrue(plan.kitchenCells.isDisjoint(with: plan.hallwayCells))
    }

    func testBoxReusesExistingDivider() throws {
        let floorplan = replacing(map(room: { _, y in y < 3 ? 1 : 2 }), resolution: 1000)
        let plan = try RoomPartitionPlanner.makeBox(floorplan: floorplan, sourceRoomIDs: [1, 2],
            rectangle: .init(minX: 0, minY: 0, maxXExclusive: 2, maxYExclusive: 3))
        let steps = try XCTUnwrap(plan.boxSteps)
        XCTAssertEqual(steps.count, 2)
        guard case .split(let original, let line) = steps[0].operation else {
            return XCTFail("Expected only the missing vertical split")
        }
        XCTAssertEqual(original.count, 18)
        XCTAssertEqual(line.start.x, 2)
        XCTAssertEqual(line.end.x, 2)
        guard case .merge = steps[1].operation else { return XCTFail("Expected the remainder merge") }
    }

    func testBoxMergesExistingPiecesBeforeCutsThatWouldCreateTinyStrips() throws {
        let floorplan = replacing(map(width: 40, height: 40, room: { _, y in y < 10 ? 1 : 2 }),
                                  resolution: 60)
        let plan = try RoomPartitionPlanner.makeBox(floorplan: floorplan, sourceRoomIDs: [1, 2],
            rectangle: .init(minX: 0, minY: 0, maxXExclusive: 10, maxYExclusive: 30))
        let steps = try XCTUnwrap(plan.boxSteps)
        guard case .merge = steps.first?.operation else {
            return XCTFail("The old horizontal rooms must be merged before splitting the entryway")
        }
        for step in steps {
            if case .split = step.operation {
                XCTAssertTrue(step.regions.allSatisfy { $0.count >= 139 })
            }
        }
        XCTAssertEqual(plan.kitchenCells.count, 300)
    }

    func testBoxRejectsSmallIntermediateStripBeforeAnyWrite() {
        let floorplan = map(width: 40, height: 40, room: { _, _ in 1 })
        XCTAssertThrowsError(try RoomPartitionPlanner.makeBox(floorplan: floorplan, sourceRoomIDs: [1],
            rectangle: .init(minX: 2, minY: 0, maxXExclusive: 20, maxYExclusive: 30))) {
            XCTAssertTrue($0.localizedDescription.contains("temporary room"))
        }
    }

    func testBoxReadbackAllowsObservedEdgeFlagsButRejectsInteriorAndUnknownChanges() throws {
        let original = map(width: 40, height: 40, room: { _, _ in 1 })
        let plan = try RoomPartitionPlanner.makeBox(floorplan: original, sourceRoomIDs: [1],
            rectangle: .init(minX: 0, minY: 0, maxXExclusive: 20, maxYExclusive: 40))
        let saved = relabel(original, regions: [plan.kitchenCells, plan.hallwayCells], ids: [1, 2])
        var pixels = saved.pixels
        // A wall cell at the outside perimeter is re-rasterized by firmware.
        pixels[0] = 0x10000020
        let rounded = replacing(saved, pixels: pixels)
        XCTAssertEqual(try plan.validateFinalPartition(rounded), [1, 2])
        pixels = saved.pixels
        pixels[20 * 40 + 8] = 0x10000020
        XCTAssertThrowsError(try plan.validateFinalPartition(replacing(saved, pixels: pixels)))
        pixels = saved.pixels
        pixels[0] ^= 0x40000000
        XCTAssertThrowsError(try plan.validateFinalPartition(replacing(saved, pixels: pixels)))
        pixels = saved.pixels
        pixels[20 * 40 + 8] = (pixels[20 * 40 + 8] & ~0xff00) | 2 << 8
        XCTAssertThrowsError(try plan.validateFinalPartition(replacing(saved, pixels: pixels)))
    }

    func testBoxAcceptsOnlyFootprintVerifiedRenumberingOfOtherRooms() throws {
        let initial = map(width: 40, height: 40, room: { x, _ in x < 30 ? 1 : 9 })
        var originalPixels = initial.pixels
        originalPixels[20 * 40 + 30] = 0x10000910
        let original = replacing(initial, pixels: originalPixels)
        let plan = try RoomPartitionPlanner.makeBox(floorplan: original, sourceRoomIDs: [1],
            rectangle: .init(minX: 0, minY: 0, maxXExclusive: 15, maxYExclusive: 40))
        let saved = relabel(original, regions: [plan.kitchenCells, plan.hallwayCells], ids: [1, 2])
        var pixels = saved.pixels.map { raw in
            MapPixel(rawValue: raw).roomID == 9 ? (raw & ~0xff00) | 3 << 8 : raw
        }
        // Firmware also reassigns one non-navigable boundary cell to its neighbor.
        pixels[20 * 40 + 30] = 0x10000210
        let rooms = saved.rooms.map { RobotRoom(id: $0.id == 9 ? 3 : $0.id, name: $0.name) }
        XCTAssertEqual(try plan.validateFinalPartition(replacing(saved, pixels: pixels, rooms: rooms)), [1, 2])
        var corrupt = pixels
        corrupt[20 * 40 + 35] = (corrupt[20 * 40 + 35] & ~0xff00) | 2 << 8
        XCTAssertThrowsError(try plan.validateFinalPartition(replacing(saved, pixels: corrupt, rooms: rooms)))
    }

    func testBoxPreservesUnchangedLegacyEmptyRoomRecords() throws {
        let grid = map(width: 40, height: 40, room: { _, _ in 1 })
        let original = replacing(grid, rooms: grid.rooms + [RobotRoom(id: 9, name: "Old divider")])
        let plan = try RoomPartitionPlanner.makeBox(floorplan: original, sourceRoomIDs: [1],
            rectangle: .init(minX: 0, minY: 0, maxXExclusive: 20, maxYExclusive: 40))
        let saved = relabel(original, regions: [plan.kitchenCells, plan.hallwayCells], ids: [1, 2])
        XCTAssertEqual(try plan.validateFinalPartition(saved), [1, 2])
        let missing = replacing(saved, rooms: saved.rooms.filter { $0.id != 9 })
        XCTAssertThrowsError(try plan.validateFinalPartition(missing))
    }

    func testBoxSnapsToExistingEdgeWithinOneCellInsteadOfMakingStrip() throws {
        let floorplan = map(width: 40, height: 40, room: { _, _ in 1 })
        let plan = try RoomPartitionPlanner.makeBox(floorplan: floorplan, sourceRoomIDs: [1],
            rectangle: .init(minX: 1, minY: 0, maxXExclusive: 20, maxYExclusive: 30))
        XCTAssertEqual(plan.rectangle.minX, 0)
        XCTAssertEqual(plan.rectangle.maxXExclusive, 20)
        XCTAssertEqual(plan.rectangle.maxYExclusive, 30)
    }

    func testBoxRejectsDisconnectedRemainder() {
        let floorplan = map(room: { _, _ in 1 })
        XCTAssertThrowsError(try RoomPartitionPlanner.makeBox(floorplan: floorplan, sourceRoomIDs: [1],
            rectangle: .init(minX: 2, minY: 0, maxXExclusive: 4, maxYExclusive: 6)))
    }

    private func map(width: Int = 6, height: Int = 6, room: (Int, Int) -> Int = { x, y in x > y ? 1 : 2 }) -> Floorplan {
        var ids = Set<Int>(), pixels = [UInt32]()
        for rawY in 0..<height {
            for x in 0..<width {
                let id = room(x, height - 1 - rawY)
                if id > 0 { ids.insert(id) }
                pixels.append(id > 0 ? 0x10000001 | UInt32(id) << 8 : 0)
            }
        }
        return Floorplan(mapID: 1, width: width, height: height, resolution: 60,
                         rooms: ids.sorted().map { RobotRoom(id: $0, name: "Room \($0)") }, pixels: pixels)
    }

    private func replacing(_ map: Floorplan, mapID: Int? = nil, pixels: [UInt32]? = nil,
                           rooms: [RobotRoom]? = nil, resolution: Int? = 60) -> Floorplan {
        Floorplan(mapID: mapID ?? map.mapID, width: map.width, height: map.height, resolution: resolution,
                  rooms: rooms ?? map.rooms, pixels: pixels ?? map.pixels)
    }

    private func plan(_ map: Floorplan? = nil) throws -> RoomPartitionPlan {
        try RoomPartitionPlanner.make(floorplan: map ?? self.map(), sourceRoomIDs: [1, 2],
             rectangle: .init(minX: 3, minY: 2, maxXExclusive: 6, maxYExclusive: 6))
    }

    private func relabel(_ map: Floorplan, regions: [Set<Int>], ids: [Int]) -> Floorplan {
        var pixels = map.pixels
        let source = regions.reduce(into: Set<Int>()) { $0.formUnion($1) }
        let oldIDs = Set(source.map { MapPixel(rawValue: map.pixels[$0]).roomID })
        for (cells, id) in zip(regions, ids) {
            for index in cells {
                pixels[index] = (pixels[index] & ~0xff00) | UInt32(id) << 8
            }
        }
        let rooms = map.rooms.filter { !oldIDs.contains($0.id) } + ids.map { RobotRoom(id: $0, name: "New \($0)") }
        return replacing(map, pixels: pixels, rooms: rooms)
    }

    private func mapWithUnreachableIsland(points: [(Int, Int)] = [(7, 7)], markedUnreachable: Bool = true) -> Floorplan {
        let original = map(width: 8, height: 8) { x, y in
            if x == 7 && y == 1 { return 3 }
            if x < 6 && y < 6 { return x > y ? 1 : 2 }
            return points.contains(where: { $0.0 == x && $0.1 == y }) ? 1 : 0
        }
        var pixels = original.pixels
        for (x, y) in points {
            let index = (original.height - 1 - y) * original.width + x
            pixels[index] = (pixels[index] & ~0xff) | (markedUnreachable ? 0x13 : 0x03)
        }
        return replacing(original, pixels: pixels)
    }

    private func unreachableIslandPlan(_ floorplan: Floorplan) throws -> RoomPartitionPlan {
        try RoomPartitionPlanner.make(floorplan: floorplan, sourceRoomIDs: [1, 2],
            rectangle: .init(minX: 3, minY: 3, maxXExclusive: 8, maxYExclusive: 8))
    }

    func testBottomRightRectangleMakesTwoCutsAndAnLShapedRemainder() throws {
        let plan = try plan()
        XCTAssertEqual(plan.corner, .bottomRight)
        XCTAssertEqual(plan.sourceCells.count, 36)
        XCTAssertEqual(plan.kitchenCells.count, 12)
        XCTAssertEqual(plan.hallwayCells.count, 24)
        XCTAssertEqual(plan.kitchenCells.union(plan.hallwayCells), plan.sourceCells)
        XCTAssertTrue(plan.kitchenCells.isDisjoint(with: plan.hallwayCells))
        XCTAssertEqual(plan.horizontalCut, .init(start: .init(x: 0, y: 2), end: .init(x: 6, y: 2)))
        XCTAssertEqual(plan.verticalCut, .init(start: .init(x: 3, y: 2), end: .init(x: 3, y: 6)))
        // Bottom-right display region maps into the lowest raw rows.
        XCTAssertTrue(plan.kitchenCells.contains(3))
        XCTAssertFalse(plan.kitchenCells.contains(33))
    }

    func testAllFourCornersAndSingleAlreadyMergedRoomAreSupported() throws {
        let oneRoom = map(room: { _, _ in 7 })
        let cases: [(RoomPartitionCorner, RoomGridRectangle)] = [
            (.topLeft, .init(minX: 0, minY: 0, maxXExclusive: 3, maxYExclusive: 2)),
            (.topRight, .init(minX: 3, minY: 0, maxXExclusive: 6, maxYExclusive: 2)),
            (.bottomLeft, .init(minX: 0, minY: 4, maxXExclusive: 3, maxYExclusive: 6)),
            (.bottomRight, .init(minX: 3, minY: 4, maxXExclusive: 6, maxYExclusive: 6)),
        ]
        for (corner, rectangle) in cases {
            let result = try RoomPartitionPlanner.make(floorplan: oneRoom, sourceRoomIDs: [7], rectangle: rectangle)
            XCTAssertEqual(result.corner, corner)
            XCTAssertEqual(result.kitchenCells.count, 6)
            XCTAssertEqual(result.hallwayCells.count, 30)
        }
    }

    func testSourceBoundsUseFullImageAndIgnoreUnselectedRooms() throws {
        let floorplan = map(width: 8, height: 8) { x, y in
            if x == 0 && y == 0 { return 3 }
            return (1...6).contains(x) && (1...6).contains(y) ? (x > y ? 1 : 2) : 0
        }
        XCTAssertEqual(try RoomPartitionPlanner.sourceBounds(floorplan: floorplan, sourceRoomIDs: [1, 2]),
                       .init(minX: 1, minY: 1, maxXExclusive: 7, maxYExclusive: 7))
        let result = try RoomPartitionPlanner.make(floorplan: floorplan, sourceRoomIDs: [1, 2],
             rectangle: .init(minX: 4, minY: 3, maxXExclusive: 7, maxYExclusive: 7))
        XCTAssertFalse(result.sourceCells.contains(56))
        let readback = relabel(floorplan, regions: [result.kitchenCells, result.hallwayCells], ids: [10, 11])
        XCTAssertEqual(try result.validateFinalPartition(readback), [10, 11])
    }

    func testUnassignedInteriorCellsStayUntouchedInsteadOfBecomingNewFloor() throws {
        let floorplan = map { x, y in x == 4 && y == 4 ? 0 : (x > y ? 1 : 2) }
        let result = try plan(floorplan)
        let hole = (6 - 1 - 4) * 6 + 4
        XCTAssertFalse(result.sourceCells.contains(hole))
        XCTAssertEqual(result.kitchenCells.count, 11)
        let readback = relabel(floorplan, regions: [result.kitchenCells, result.hallwayCells], ids: [10, 11])
        XCTAssertEqual(readback.pixels[hole], 0)
        XCTAssertNoThrow(try result.validateFinalPartition(readback))
    }

    func testUnknownSourceMissingSourceAndDuplicateCatalogAreRejected() throws {
        let floorplan = map()
        XCTAssertThrowsError(try RoomPartitionPlanner.sourceBounds(floorplan: floorplan, sourceRoomIDs: []))
        XCTAssertThrowsError(try RoomPartitionPlanner.sourceBounds(floorplan: floorplan, sourceRoomIDs: [3]))
        let absent = replacing(floorplan, rooms: floorplan.rooms + [RobotRoom(id: 3, name: "Absent")])
        XCTAssertThrowsError(try RoomPartitionPlanner.sourceBounds(floorplan: absent, sourceRoomIDs: [3]))
        let duplicate = replacing(floorplan, rooms: floorplan.rooms + [floorplan.rooms[0]])
        XCTAssertThrowsError(try RoomPartitionPlanner.sourceBounds(floorplan: duplicate, sourceRoomIDs: [1, 2]))
    }

    func testRectangleCannotLeaveBoundsFloatInMiddleOrConsumeWholeHeight() throws {
        for rectangle in [
            RoomGridRectangle(minX: -1, minY: 2, maxXExclusive: 6, maxYExclusive: 6),
            .init(minX: 1, minY: 1, maxXExclusive: 5, maxYExclusive: 5),
            .init(minX: 3, minY: 0, maxXExclusive: 6, maxYExclusive: 6),
            .init(minX: 6, minY: 2, maxXExclusive: 6, maxYExclusive: 6),
        ] {
            XCTAssertThrowsError(try RoomPartitionPlanner.make(floorplan: map(), sourceRoomIDs: [1, 2], rectangle: rectangle))
        }
    }

    func testRectangleCannotAbsorbThirdRoomEvenIfItIsInsideSourceBoundingBox() {
        let floorplan = map { x, y in x == 4 && y == 4 ? 3 : (x > y ? 1 : 2) }
        let named = replacing(floorplan, rooms: floorplan.rooms.map {
            RobotRoom(id: $0.id, name: $0.id == 3 ? "Dining room" : $0.name)
        })
        XCTAssertThrowsError(try plan(named)) { error in
            XCTAssertTrue(error.localizedDescription.contains("overlaps Dining room"))
        }
        let missingName = replacing(floorplan, rooms: floorplan.rooms.filter { $0.id != 3 })
        XCTAssertThrowsError(try plan(missingName)) { error in
            XCTAssertTrue(error.localizedDescription.contains("overlaps Room 3"))
        }
    }

    func testForeignUnreachableCellInsideRectangleRemainsAnExactUnselectedHole() throws {
        let original = map { x, y in x == 4 && y == 4 ? 3 : (x > y ? 1 : 2) }
        let foreign = (6 - 1 - 4) * 6 + 4
        var pixels = original.pixels; pixels[foreign] |= 0x10
        let floorplan = replacing(original, pixels: pixels), result = try plan(floorplan)
        for region in [result.sourceCells, result.kitchenCells, result.hallwayCells,
                       result.horizontalRemainderCells, result.cornerBandCells, result.sideRemainderCells] {
            XCTAssertFalse(region.contains(foreign))
        }
        XCTAssertEqual(result.kitchenCells.count, 11)
        let valid = relabel(floorplan, regions: [result.kitchenCells, result.hallwayCells], ids: [10, 11])
        XCTAssertEqual(valid.pixels[foreign], floorplan.pixels[foreign])
        XCTAssertNoThrow(try result.validateFinalPartition(valid))
        for changedRaw in [valid.pixels[foreign] ^ 0x01, valid.pixels[foreign] & ~0x10,
                           (valid.pixels[foreign] & ~0xff00) | 10 << 8, UInt32(0)] {
            var changed = valid.pixels; changed[foreign] = changedRaw
            XCTAssertThrowsError(try result.validateFinalPartition(replacing(valid, pixels: changed)))
        }
    }

    func testForeignWallWithoutUnreachableFlagStillBlocksRectangle() {
        let original = map { x, y in x == 4 && y == 4 ? 3 : (x > y ? 1 : 2) }
        let foreign = (6 - 1 - 4) * 6 + 4
        XCTAssertThrowsError(try plan(original))
        var pixels = original.pixels; pixels[foreign] |= 0x20
        XCTAssertThrowsError(try plan(replacing(original, pixels: pixels)))
    }

    func testUnknownRoomUnreachableCellStillBlocksRectangle() {
        let original = map { x, y in x == 4 && y == 4 ? 3 : (x > y ? 1 : 2) }
        var pixels = original.pixels; pixels[(6 - 1 - 4) * 6 + 4] |= 0x10
        let missingCatalogEntry = replacing(original, pixels: pixels, rooms: original.rooms.filter { $0.id != 3 })
        XCTAssertThrowsError(try plan(missingCatalogEntry)) { error in
            XCTAssertTrue(error.localizedDescription.contains("overlaps Room 3"))
        }
    }

    func testForeignUnreachableCellOnDividerStillBlocksCut() {
        let original = map { x, y in x == 3 && y == 3 ? 3 : (x > y ? 1 : 2) }
        var pixels = original.pixels; pixels[(6 - 1 - 3) * 6 + 3] |= 0x10
        XCTAssertThrowsError(try plan(replacing(original, pixels: pixels))) { error in
            XCTAssertTrue(error.localizedDescription.contains("divider crosses another room"))
        }
    }

    func testEntireDividerMustAvoidThirdRoomOutsideKitchenRectangle() {
        // This third room is outside the requested Kitchen but touches the
        // first divider's upper neighboring row on the Hallway side.
        let floorplan = map { x, y in x == 1 && y == 1 ? 3 : (x > y ? 1 : 2) }
        XCTAssertThrowsError(try plan(floorplan))
    }

    func testHorizontalDividerStopsBeforeUnrelatedRoomBeyondNecessaryCut() throws {
        // The upper wing makes the source bounds wider than the actual cut.
        // The third room touches that unused extension, not the selected cut.
        let floorplan = map(width: 8, height: 8) { x, y in
            if x == 0 && y == 3 { return 3 }
            return y < 3 || x >= 2 ? 1 : 0
        }
        let result = try RoomPartitionPlanner.make(floorplan: floorplan, sourceRoomIDs: [1],
            rectangle: .init(minX: 5, minY: 4, maxXExclusive: 8, maxYExclusive: 8))
        XCTAssertEqual(result.sourceBounds.minX, 0)
        XCTAssertEqual(result.horizontalCut, .init(start: .init(x: 2, y: 4), end: .init(x: 8, y: 4)))
        XCTAssertEqual(result.verticalCut, .init(start: .init(x: 5, y: 4), end: .init(x: 5, y: 8)))
        let readback = relabel(floorplan, regions: [result.kitchenCells, result.hallwayCells], ids: [10, 11])
        XCTAssertNoThrow(try result.validateFinalPartition(readback))
        XCTAssertEqual(readback.pixels[(8 - 1 - 3) * 8], floorplan.pixels[(8 - 1 - 3) * 8])
    }

    func testVerticalDividerTrimsToCornerBandAdjacencies() throws {
        // The lower-left wing extends the band below the Kitchen. A third
        // room beside that wing must not lengthen or obstruct the real cut.
        let floorplan = map(width: 8, height: 8) { x, y in
            if x == 3 && y == 7 { return 3 }
            return y < 6 || x < 2 ? 1 : 0
        }
        let result = try RoomPartitionPlanner.make(floorplan: floorplan, sourceRoomIDs: [1],
            rectangle: .init(minX: 4, minY: 3, maxXExclusive: 8, maxYExclusive: 8))
        XCTAssertEqual(result.horizontalCut, .init(start: .init(x: 0, y: 3), end: .init(x: 8, y: 3)))
        XCTAssertEqual(result.verticalCut, .init(start: .init(x: 4, y: 3), end: .init(x: 4, y: 6)))
        let readback = relabel(floorplan, regions: [result.kitchenCells, result.hallwayCells], ids: [10, 11])
        XCTAssertNoThrow(try result.validateFinalPartition(readback))
    }

    func testDisconnectedSourceErrorDistinguishesExistingMapFromProposedCut() {
        let disconnected = map { x, _ in x == 2 ? 0 : (x < 2 ? 1 : 2) }
        XCTAssertThrowsError(try plan(disconnected)) { error in
            XCTAssertTrue(error.localizedDescription.contains("selected area contains disconnected cells"))
        }
        let connectedSource = map(width: 8, height: 8) { x, y in
            // A top connecting bar joins two legs; the bottom-right rectangle
            // can deliberately miss both legs while the source stays intact.
            y < 2 || x < 2 || x == 4 ? 1 : 0
        }
        XCTAssertThrowsError(try RoomPartitionPlanner.make(floorplan: connectedSource, sourceRoomIDs: [1],
            rectangle: .init(minX: 5, minY: 4, maxXExclusive: 8, maxYExclusive: 8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("corner room would be empty or disconnected"))
        }
    }

    func testDisconnectedAndDiagonalOnlySourcesAreRejected() {
        let disconnected = map { x, _ in x == 2 ? 0 : (x < 2 ? 1 : 2) }
        XCTAssertThrowsError(try plan(disconnected))
        let diagonal = map { x, y in x == y ? (x < 3 ? 1 : 2) : 0 }
        XCTAssertThrowsError(try plan(diagonal))
    }

    func testExistingSingletonUnreachableCellRemainsInBoundsAndEveryExactPartition() throws {
        let original = mapWithUnreachableIsland(), result = try unreachableIslandPlan(original)
        let orphan = 7 // Display (7,7), raw row zero.
        XCTAssertEqual(result.sourceBounds, .init(minX: 0, minY: 0, maxXExclusive: 8, maxYExclusive: 8))
        XCTAssertEqual(result.sourceCells.count, 37)
        XCTAssertTrue(result.sourceCells.contains(orphan))
        XCTAssertTrue(result.kitchenCells.contains(orphan))
        XCTAssertEqual(result.kitchenCells.union(result.hallwayCells), result.sourceCells)
        let stages = [[result.sourceCells], [result.horizontalRemainderCells, result.cornerBandCells],
                      [result.horizontalRemainderCells, result.sideRemainderCells, result.kitchenCells],
                      [result.kitchenCells, result.hallwayCells]]
        for regions in stages {
            let ids = Array(10..<(10 + regions.count))
            let latest = relabel(original, regions: regions, ids: ids)
            XCTAssertEqual(try result.validatePartition(regions: regions, latest: latest), ids)
            XCTAssertEqual(latest.pixels[orphan] & ~0xff00, original.pixels[orphan] & ~0xff00)
            let foreign = (8 - 1 - 1) * 8 + 7
            XCTAssertEqual(latest.pixels[foreign], original.pixels[foreign])
        }
    }

    func testUnflaggedSingletonAndMixedUnreachableComponentAreStillRejected() {
        XCTAssertThrowsError(try unreachableIslandPlan(mapWithUnreachableIsland(markedUnreachable: false)))
        let mixed = mapWithUnreachableIsland(points: [(7, 7), (7, 6)])
        var pixels = mixed.pixels; pixels[7] &= ~0x10
        XCTAssertThrowsError(try unreachableIslandPlan(replacing(mixed, pixels: pixels)))
    }

    func testExistingDetachedUnreachableComponentsRemainInEveryExactPartition() throws {
        let points = [(7, 7), (7, 6), (6, 7), (1, 7), (2, 7)]
        let original = mapWithUnreachableIsland(points: points), result = try unreachableIslandPlan(original)
        let markers = Set(points.map { (8 - 1 - $0.1) * 8 + $0.0 })
        XCTAssertEqual(result.sourceCells.count, 41)
        XCTAssertTrue(markers.isSubset(of: result.sourceCells))
        XCTAssertEqual(result.sourceBounds, .init(minX: 0, minY: 0, maxXExclusive: 8, maxYExclusive: 8))
        let stages = [[result.sourceCells], [result.horizontalRemainderCells, result.cornerBandCells],
                      [result.horizontalRemainderCells, result.sideRemainderCells, result.kitchenCells],
                      [result.kitchenCells, result.hallwayCells]]
        for regions in stages {
            let ids = Array(10..<(10 + regions.count))
            let latest = relabel(original, regions: regions, ids: ids)
            XCTAssertEqual(try result.validatePartition(regions: regions, latest: latest), ids)
            for marker in markers { XCTAssertEqual(latest.pixels[marker] & ~0xff00, original.pixels[marker] & ~0xff00) }
        }
    }

    func testDetachedUnreachableCellsCannotDisappearChangeBitsOrGrowOnReadback() throws {
        let original = mapWithUnreachableIsland(points: [(7, 7), (7, 6)]), result = try unreachableIslandPlan(original)
        let valid = relabel(original, regions: [result.kitchenCells, result.hallwayCells], ids: [10, 11])
        XCTAssertNoThrow(try result.validateFinalPartition(valid))
        for marker in [7, 15] {
            for invalidPixel in [UInt32(0), (valid.pixels[marker] & ~0xff00) | 11 << 8,
                                 valid.pixels[marker] & ~0x10, valid.pixels[marker] ^ 0x02] {
                var pixels = valid.pixels; pixels[marker] = invalidPixel
                XCTAssertThrowsError(try result.validateFinalPartition(replacing(valid, pixels: pixels)))
            }
        }
        var enlarged = valid.pixels
        enlarged[6] = 10 << 8 | 0x13
        XCTAssertThrowsError(try result.validateFinalPartition(replacing(valid, pixels: enlarged)))
    }

    func testDetachedUnreachableComponentsNeedOneLargerMainWithUnflaggedCells() {
        let equal = map(width: 8, height: 8) { x, y in
            (x < 2 && y < 2) || (x < 4 && y == 7) ? 1 : 0
        }
        var tied = equal.pixels
        for x in 0..<4 { tied[x] |= 0x10 }
        let noInterior = mapWithUnreachableIsland(points: [(7, 7), (7, 6)])
        let allUnreachable = noInterior.pixels.map { MapPixel(rawValue: $0).roomID == 0 ? $0 : $0 | 0x10 }
        for (floorplan, sources) in [(replacing(equal, pixels: tied), Set([1])),
                                     (replacing(noInterior, pixels: allUnreachable), Set([1, 2]))] {
            XCTAssertThrowsError(try RoomPartitionPlanner.make(floorplan: floorplan, sourceRoomIDs: sources,
                rectangle: .init(minX: 1, minY: 3, maxXExclusive: 8, maxYExclusive: 8))) { error in
                XCTAssertTrue(error.localizedDescription.contains("selected area contains disconnected cells"))
            }
        }
    }

    func testNewlyDisconnectedUnreachableCellCannotUseExistingSingletonException() {
        let original = map(width: 8, height: 8) { x, y in
            if (x == 7 && y == 7) || (x == 5 && y == 3) { return 1 }
            return (x < 6 && y < 3) || (x < 4 && y < 6) ? 1 : 0
        }
        var pixels = original.pixels
        for (x, y) in [(7, 7), (5, 3)] {
            pixels[(8 - 1 - y) * 8 + x] |= 0x10
        }
        // (5,3) is connected through (5,2) before the proposed cut. It must
        // not become an ignored singleton just because the cut isolates it.
        XCTAssertThrowsError(try RoomPartitionPlanner.make(floorplan: replacing(original, pixels: pixels),
            sourceRoomIDs: [1], rectangle: .init(minX: 3, minY: 3, maxXExclusive: 8, maxYExclusive: 8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("corner room would be empty or disconnected"))
        }
    }

    func testRegionContainingOnlyExemptUnreachableComponentsIsRejected() {
        for points in [[(7, 7)], [(7, 7), (7, 6)]] {
            XCTAssertThrowsError(try RoomPartitionPlanner.make(floorplan: mapWithUnreachableIsland(points: points), sourceRoomIDs: [1, 2],
                rectangle: .init(minX: 6, minY: 6, maxXExclusive: 8, maxYExclusive: 8))) { error in
                XCTAssertTrue(error.localizedDescription.contains("corner room would be empty or disconnected"))
            }
        }
    }

    func testSelectedRoomCannotConsistOnlyOfExemptUnreachableComponents() {
        for points in [[(7, 7)], [(7, 7), (7, 6)]] {
            let original = map(width: 8, height: 8) { x, y in
                if points.contains(where: { $0.0 == x && $0.1 == y }) { return 2 }
                return x < 6 && y < 6 ? 1 : 0
            }
            var pixels = original.pixels
            for (x, y) in points { pixels[(8 - 1 - y) * 8 + x] |= 0x10 }
            XCTAssertThrowsError(try unreachableIslandPlan(replacing(original, pixels: pixels))) { error in
                XCTAssertTrue(error.localizedDescription.contains("no connected area beyond detached unreachable components"))
            }
        }
    }

    func testOrphanLossWrongLabelAndUnreachableBitRemovalFailExactReadback() throws {
        let original = mapWithUnreachableIsland(), result = try unreachableIslandPlan(original)
        let valid = relabel(original, regions: [result.kitchenCells, result.hallwayCells], ids: [10, 11])
        XCTAssertNoThrow(try result.validateFinalPartition(valid))
        let orphan = 7
        for invalidPixel in [UInt32(0), (valid.pixels[orphan] & ~0xff00) | 11 << 8,
                             valid.pixels[orphan] & ~0x10, valid.pixels[orphan] ^ 0x02] {
            var pixels = valid.pixels; pixels[orphan] = invalidPixel
            XCTAssertThrowsError(try result.validateFinalPartition(replacing(valid, pixels: pixels)))
        }
    }

    func testFreshBaselineRequiresEveryOriginalRawBitAndSameMapGeometry() throws {
        let floorplan = map(), result = try plan(floorplan)
        XCTAssertNoThrow(try result.validateBaseline(floorplan))
        var pixels = floorplan.pixels; pixels[0] ^= 0x10000000
        XCTAssertThrowsError(try result.validateBaseline(replacing(floorplan, pixels: pixels)))
        XCTAssertThrowsError(try result.validateBaseline(replacing(floorplan, mapID: 2)))
        XCTAssertThrowsError(try result.validateBaseline(replacing(floorplan, resolution: 50)))
    }

    func testIntermediateAndFinalReadbackDiscoverNewIDsAndPreserveUnreachableFlags() throws {
        let floorplan = map(), result = try plan(floorplan)
        let stages = [
            [result.sourceCells],
            [result.horizontalRemainderCells, result.cornerBandCells],
            [result.horizontalRemainderCells, result.sideRemainderCells, result.kitchenCells],
            [result.kitchenCells, result.hallwayCells],
        ]
        for regions in stages {
            let ids = Array(20..<(20 + regions.count))
            let readback = relabel(floorplan, regions: regions, ids: ids)
            XCTAssertEqual(try result.validatePartition(regions: regions, latest: readback), ids)
            var changed = readback.pixels
            changed[try XCTUnwrap(result.sourceCells.first)] ^= 0x10
            XCTAssertThrowsError(try result.validatePartition(regions: regions, latest: replacing(readback, pixels: changed)))
        }
    }

    func testReadbackRejectsUnknownAttributesObstacleChangesAndUnexpectedRelabeling() throws {
        let floorplan = map(), result = try plan(floorplan)
        let valid = relabel(floorplan, regions: [result.kitchenCells, result.hallwayCells], ids: [10, 11])
        for forbiddenBit: UInt32 in [0x1, 0x8, 0x10, 0x20, 0x10000, 0x10000000] {
            var pixels = valid.pixels; pixels[0] ^= forbiddenBit
            XCTAssertThrowsError(try result.validateFinalPartition(replacing(valid, pixels: pixels)))
        }
        var pixels = valid.pixels
        let movedCell = try XCTUnwrap(result.kitchenCells.first)
        pixels[movedCell] = (pixels[movedCell] & ~0xff00) | 11 << 8
        XCTAssertThrowsError(try result.validateFinalPartition(replacing(valid, pixels: pixels)))
        let staleRoomList = replacing(valid, rooms: valid.rooms + [RobotRoom(id: 1, name: "Stale")])
        XCTAssertThrowsError(try result.validateFinalPartition(staleRoomList))
    }

    func testMatchingRegionMustBeExactAndPartitionMustCoverSourceWithoutOverlap() throws {
        let floorplan = map(), result = try plan(floorplan)
        let readback = relabel(floorplan, regions: [result.kitchenCells, result.hallwayCells], ids: [10, 11])
        XCTAssertEqual(try RoomPartitionPlanner.matchingRoomID(cells: result.kitchenCells, in: readback), 10)
        XCTAssertThrowsError(try RoomPartitionPlanner.matchingRoomID(cells: [], in: readback))
        XCTAssertThrowsError(try RoomPartitionPlanner.matchingRoomID(cells: [-1], in: readback))
        XCTAssertThrowsError(try result.matchingRoomID(cells: Set(result.kitchenCells.dropFirst()), in: readback))
        XCTAssertThrowsError(try result.validatePartition(regions: [result.kitchenCells], latest: readback))
        XCTAssertThrowsError(try result.validatePartition(regions: [result.sourceCells, result.kitchenCells], latest: readback))
    }

    func testScopedSnapshotValidationIncludesBothVersionsAndExactUnknownPayloadBytes() throws {
        let floorplan = map()
        func snapshot(device: String = "device", version: UInt32 = 7, edit: UInt32 = 9, bytes: Data = Data([1, 2, 3])) -> MapSnapshot {
            MapSnapshot(productKey: "product", deviceID: device, mapID: 1, mapVersion: version,
                        editVersion: edit, capturedAt: Date(), floorplan: floorplan, staticMapPayload: bytes)
        }
        let baseline = snapshot()
        XCTAssertNoThrow(try RoomPartitionPlanner.validate(current: snapshot(), against: baseline))
        for changed in [snapshot(device: "other"), snapshot(version: 8), snapshot(edit: 10), snapshot(bytes: Data([1, 2, 4]))] {
            XCTAssertThrowsError(try RoomPartitionPlanner.validate(current: changed, against: baseline))
        }
    }
}
