import Foundation

public struct RoomRenameTransactionError: LocalizedError, Sendable {
    public let detail: String
    public var errorDescription: String? {
        "The room names could not be verified. Reload the saved map before trying again. No edit was retried. \(detail)"
    }
}

/// Names-only edits share the normal map backup, single-send and readback path.
public enum RoomRenameTransaction {
    public static func changedNames(in floorplan: Floorplan, requested: [Int: String]) throws -> [Int: String] {
        let known = Set(floorplan.rooms.map(\.id))
        guard known.count == floorplan.rooms.count, !known.isEmpty,
              Set(requested.keys).isSubset(of: known) else {
            throw ConnectorError.invalid("Reload the saved room list before renaming rooms.")
        }
        var changed: [Int: String] = [:]
        var names: [Int: String] = [:]
        for room in floorplan.rooms {
            let name = (requested[room.id] ?? room.name).trimmingCharacters(in: .whitespacesAndNewlines)
            try NarwalCodec.validateRoomName(name)
            names[room.id] = name
            if requested[room.id] != nil, name != room.name { changed[room.id] = name }
        }
        for (id, name) in changed {
            guard !names.contains(where: { $0.key != id && $0.value.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
                throw ConnectorError.invalid("Give each room a different name.")
            }
        }
        guard changed.count <= 64 else { throw ConnectorError.invalid("Rename up to 64 rooms at a time.") }
        return changed
    }

    public static func commit(
        baseline: MapSnapshot,
        names requested: [Int: String],
        read: @Sendable () async throws -> MapSnapshot,
        apply: @Sendable (MapSnapshot, [RoomMapOperation]) async throws -> MapEditCommitResult,
        preserveReadback: (@Sendable (MapSnapshot) throws -> Void)? = nil
    ) async throws -> MapSnapshot {
        let names = try changedNames(in: baseline.floorplan, requested: requested)
        guard !names.isEmpty else { return baseline }
        let operations = names.keys.sorted().map { RoomMapOperation.rename(roomID: $0, name: names[$0]!) }
        _ = try NarwalCodec.roomOperationRequest(uuid: String(repeating: "0", count: 32), baseline: baseline, operations: operations)
        try Task.checkCancellation()
        let fresh = try await read()
        try MapEditTransaction.validate(current: fresh, baseline: baseline)
        guard fresh.floorplan == baseline.floorplan else { throw MapEditError.staleSnapshot }
        try Task.checkCancellation()
        // From this point onward, a failure is not permission to resend.
        do {
            let result = try await apply(fresh, operations)
            let saved = result.snapshot
            if let preserveReadback { try preserveReadback(saved) }
            else { _ = try MapSnapshotStore.preserveReadback(saved) }
            guard saved.productKey == fresh.productKey, saved.deviceID == fresh.deviceID,
                  saved.mapID == fresh.mapID, saved.mapVersion >= fresh.mapVersion,
                  saved.editVersion > fresh.editVersion else { throw MapEditError.outcomeUnknown }
            try NarwalCodec.validateRoomRenameReadback(baseline: fresh, current: saved, names: names)
            try Task.checkCancellation()
            return saved
        } catch {
            throw RoomRenameTransactionError(detail: error.localizedDescription)
        }
    }
}
