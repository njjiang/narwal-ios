import Foundation

public struct RoomMergeTransactionError: LocalizedError, Sendable {
    public let detail: String
    public var errorDescription: String? {
        "The room merge could not be verified. Reload the saved map before trying again. No edit was retried. \(detail)"
    }
}

/// One reviewed two-room merge. The existing source footprints are preserved
/// exactly; a merge cannot authorize changes to walls, other rooms or map data.
public enum RoomMergeTransaction {
    public static func validate(floorplan: Floorplan, sourceRoomIDs: Set<Int>) throws {
        _ = try sourceCells(in: floorplan, sourceRoomIDs: sourceRoomIDs)
    }

    public static func demoMergedFloorplan(floorplan: Floorplan, sourceRoomIDs: Set<Int>) throws -> Floorplan {
        let cells = try sourceCells(in: floorplan, sourceRoomIDs: sourceRoomIDs)
        let retainedID = sourceRoomIDs.min()!
        var pixels = floorplan.pixels
        for index in cells { pixels[index] = (pixels[index] & ~0xff00) | UInt32(retainedID << 8) }
        return Floorplan(mapID: floorplan.mapID, width: floorplan.width, height: floorplan.height,
            resolution: floorplan.resolution,
            rooms: floorplan.rooms.filter { !sourceRoomIDs.contains($0.id) || $0.id == retainedID },
            pixels: pixels, mapRevision: floorplan.mapRevision)
    }

    public static func commit(
        baseline: MapSnapshot,
        sourceRoomIDs: Set<Int>,
        read: @Sendable () async throws -> MapSnapshot,
        apply: @Sendable (MapSnapshot, [RoomMapOperation]) async throws -> MapEditCommitResult,
        preserveReadback: (@Sendable (MapSnapshot) throws -> Void)? = nil
    ) async throws -> MapSnapshot {
        let cells = try sourceCells(in: baseline.floorplan, sourceRoomIDs: sourceRoomIDs)
        let ids = sourceRoomIDs.sorted()
        let operations = [RoomMapOperation.merge(roomID1: ids[0], roomID2: ids[1], newRoomID: ids[0])]
        _ = try NarwalCodec.roomOperationRequest(uuid: String(repeating: "0", count: 32),
                                                baseline: baseline, operations: operations)
        try Task.checkCancellation()
        let fresh = try await read()
        try MapEditTransaction.validate(current: fresh, baseline: baseline)
        guard fresh.floorplan == baseline.floorplan,
              fresh.maximumRoomCount == baseline.maximumRoomCount else { throw MapEditError.staleSnapshot }
        try Task.checkCancellation()
        // A failure after this single send never grants permission to resend.
        do {
            let result = try await apply(fresh, operations)
            let saved = result.snapshot
            if let preserveReadback { try preserveReadback(saved) }
            else { _ = try MapSnapshotStore.preserveReadback(saved) }
            guard saved.productKey == fresh.productKey, saved.deviceID == fresh.deviceID,
                  saved.mapID == fresh.mapID, saved.mapVersion >= fresh.mapVersion,
                  saved.editVersion > fresh.editVersion else { throw MapEditError.outcomeUnknown }
            try NarwalCodec.validateRoomEditReadback(baseline: fresh, current: saved,
                mutableRoomIDs: sourceRoomIDs, precedingSnapshot: fresh, operations: operations)
            try validateMergedGeometry(baseline: fresh.floorplan, saved: saved.floorplan,
                                       sourceRoomIDs: sourceRoomIDs, cells: cells)
            try Task.checkCancellation()
            return saved
        } catch {
            throw RoomMergeTransactionError(detail: error.localizedDescription)
        }
    }

    private static func sourceCells(in map: Floorplan, sourceRoomIDs: Set<Int>) throws -> Set<Int> {
        guard sourceRoomIDs.count == 2 else {
            throw ConnectorError.invalid("Select exactly two adjoining rooms to merge.")
        }
        // Reuse the planner's bounded grid and current room-list validation.
        _ = try RoomPartitionPlanner.sourceBounds(floorplan: map, sourceRoomIDs: sourceRoomIDs)
        let cells = Set(map.pixels.indices.filter { sourceRoomIDs.contains(MapPixel(rawValue: map.pixels[$0]).roomID) })
        let walkable = Set(cells.filter {
            let pixel = MapPixel(rawValue: map.pixels[$0])
            return !pixel.isWall && !pixel.isUnreachable
        })
        guard Set(walkable.map { MapPixel(rawValue: map.pixels[$0]).roomID }) == sourceRoomIDs,
              connected(walkable, width: map.width, height: map.height) else {
            throw ConnectorError.invalid("Choose two adjoining rooms with a connected floor area.")
        }
        // Preserve the planner's narrow allowance for already detached,
        // entirely unreachable islands. It never changes the expected raster.
        var remaining = cells
        var components: [Set<Int>] = []
        while let first = remaining.first {
            let component = flood(from: first, cells: remaining, width: map.width, height: map.height)
            remaining.subtract(component); components.append(component)
        }
        if components.count > 1 {
            components.sort { $0.count > $1.count }
            guard components[0].count > components[1].count,
                  walkable.isSubset(of: components[0]),
                  components.dropFirst().allSatisfy({ component in
                      component.allSatisfy { MapPixel(rawValue: map.pixels[$0]).isUnreachable }
                  }) else {
                throw ConnectorError.invalid("The selected rooms contain disconnected areas. Review the map before merging.")
            }
        }
        return cells
    }

    private static func validateMergedGeometry(baseline: Floorplan, saved: Floorplan,
                                               sourceRoomIDs: Set<Int>, cells: Set<Int>) throws {
        guard saved.mapID == baseline.mapID, saved.width == baseline.width, saved.height == baseline.height,
              saved.resolution == baseline.resolution, saved.pixels.count == baseline.pixels.count else {
            throw ConnectorError.invalid("The merged map changed its geometry. Inspect it before continuing.")
        }
        let retainedID = sourceRoomIDs.min()!
        let resultID = try RoomPartitionPlanner.matchingRoomID(cells: cells, in: saved)
        let foreign = baseline.rooms.filter { !sourceRoomIDs.contains($0.id) }
        guard resultID == retainedID,
              Set(saved.rooms.map(\.id)) == Set(foreign.map(\.id)).union([retainedID]),
              saved.rooms.first(where: { $0.id == retainedID }) == baseline.rooms.first(where: { $0.id == retainedID }),
              foreign.allSatisfy({ saved.rooms.contains($0) }) else {
            throw ConnectorError.invalid("The merge changed room identifiers or names unexpectedly. Inspect the saved map before continuing.")
        }
        for index in baseline.pixels.indices {
            let changed = baseline.pixels[index] ^ saved.pixels[index]
            guard cells.contains(index) ? changed & ~UInt32(0xff00) == 0 : changed == 0 else {
                throw ConnectorError.invalid("The merge changed walls or an unselected room. Inspect the saved map before continuing.")
            }
        }
    }

    private static func connected(_ cells: Set<Int>, width: Int, height: Int) -> Bool {
        guard let first = cells.first else { return false }
        return flood(from: first, cells: cells, width: width, height: height).count == cells.count
    }

    private static func flood(from first: Int, cells: Set<Int>, width: Int, height: Int) -> Set<Int> {
        var seen: Set<Int> = [first], queue = [first], cursor = 0
        while cursor < queue.count {
            let cell = queue[cursor]; cursor += 1
            let x = cell % width, y = cell / width
            let neighbors = [x > 0 ? cell - 1 : -1, x + 1 < width ? cell + 1 : -1,
                             y > 0 ? cell - width : -1, y + 1 < height ? cell + width : -1]
            for neighbor in neighbors where cells.contains(neighbor) && seen.insert(neighbor).inserted {
                queue.append(neighbor)
            }
        }
        return seen
    }
}
