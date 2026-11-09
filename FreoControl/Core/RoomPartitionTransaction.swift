import Foundation

public struct RoomPartitionTransactionError: LocalizedError, Sendable {
    public let completedSteps: Int
    public let stepLabel: String
    public let detail: String
    public var mayHaveChanged: Bool { true }
    public var errorDescription: String? {
        "The room edit stopped during: \(stepLabel). \(completedSteps) earlier step(s) were verified. Some changes may already be saved. Reload the robot’s map before continuing. No edit was retried. \(detail)"
    }
}

/// Classified from a newly reviewed baseline, never from a previous attempt's
/// progress counter or an unverified post-write response.
public enum RoomPartitionRemainingStage: String, Sendable {
    case wholeArea
    case horizontalDividerSaved
    case threePiecesSaved
    case finalPartitionSaved
    case boxEdits

    fileprivate var splitCount: Int {
        switch self {
        case .wholeArea: return 2
        case .horizontalDividerSaved: return 1
        case .threePiecesSaved, .finalPartitionSaved, .boxEdits: return 0
        }
    }
}

/// Sequential, injectable orchestration. Each operation is sent at most once;
/// every subsequent step depends on an exact, fresh, geometrically verified map.
public enum RoomPartitionTransaction {
    /// A fresh explicit Save may retain geometry already present in the reviewed
    /// map. Three selected rooms are only supported as the exact three pieces;
    /// arbitrary triples never become a new three-room merge operation.
    public static func remainingStage(plan: RoomPartitionPlan, floorplan: Floorplan) throws -> RoomPartitionRemainingStage {
        try plan.validateBaseline(floorplan)
        if let steps = plan.boxSteps { return steps.isEmpty ? .finalPartitionSaved : .boxEdits }
        switch plan.sourceRoomIDs.count {
        case 1:
            return .wholeArea
        case 2:
            if (try? plan.recognizedFinalPartition(floorplan)) != nil { return .finalPartitionSaved }
            if (try? plan.validatePartition(regions: [plan.horizontalRemainderCells, plan.cornerBandCells], latest: floorplan)) != nil {
                return .horizontalDividerSaved
            }
            return .wholeArea
        case 3:
            guard (try? plan.validatePartition(regions: [plan.horizontalRemainderCells, plan.sideRemainderCells, plan.kitchenCells], latest: floorplan)) != nil else {
                throw ConnectorError.invalid("Three selected rooms must already match the two reviewed dividers. Choose the saved pieces or review a different layout.")
            }
            return .threePiecesSaved
        default:
            throw ConnectorError.invalid("Select one area, two rooms, or the three saved divider pieces.")
        }
    }

    public static func commit(
        plan: RoomPartitionPlan,
        baseline: MapSnapshot,
        kitchenName requestedKitchenName: String,
        hallwayName requestedHallwayName: String,
        resumeOnly: Bool = false,
        read: @Sendable () async throws -> MapSnapshot,
        apply: @Sendable (MapSnapshot, [RoomMapOperation]) async throws -> MapEditCommitResult,
        preserveReadback: (@Sendable (MapSnapshot) throws -> Void)? = nil,
        progress: @Sendable (String) async -> Void
    ) async throws -> MapSnapshot {
        let kitchenName = requestedKitchenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hallwayName = requestedHallwayName.trimmingCharacters(in: .whitespacesAndNewlines)
        try NarwalCodec.validateRoomName(kitchenName)
        try NarwalCodec.validateRoomName(hallwayName)
        guard kitchenName.compare(hallwayName, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame else {
            throw ConnectorError.invalid("Use different names for the two rooms.")
        }
        let stage = try remainingStage(plan: plan, floorplan: baseline.floorplan)
        guard !resumeOnly || stage != .wholeArea else {
            throw ConnectorError.invalid("The saved rooms no longer match a completed divider stage. Reload and review the saved pieces before continuing this edit.")
        }
        let peakCount = plan.boxSteps.map { steps in
            max(baseline.floorplan.rooms.count, baseline.floorplan.rooms.count - plan.sourceRoomIDs.count +
                (steps.map { $0.regions.count }.max() ?? 0))
        } ?? (stage == .finalPartitionSaved ? baseline.floorplan.rooms.count
            : max(baseline.floorplan.rooms.count, baseline.floorplan.rooms.count - plan.sourceRoomIDs.count + 3))
        guard let limit = baseline.maximumRoomCount, limit >= peakCount else {
            throw ConnectorError.invalid(baseline.maximumRoomCount == nil
                ? "The robot did not provide its room limit. Reload the editable map before saving."
                : "This edit temporarily needs \(peakCount) rooms, which exceeds the robot’s room limit.")
        }
        let originalIDs = baseline.floorplan.rooms.map(\.id)
        guard originalIDs.allSatisfy({ (1...255).contains($0) }),
              let highestID = originalIDs.max(), highestID <= 255 - (plan.boxSteps?.filter {
                  if case .split = $0.operation { return true }
                  return false
              }.count ?? stage.splitCount),
              let originalFirstID = plan.sourceRoomIDs.sorted().first else {
            throw ConnectorError.invalid("This map does not have room identifiers available for the remaining dividers.")
        }
        let converter = try MapEditCoordinates(snapshot: baseline)
        let horizontalStart = try converter.point(plan.horizontalCut.start)
        let horizontalEnd = try converter.point(plan.horizontalCut.end)
        let verticalStart = try converter.point(plan.verticalCut.start)
        let verticalEnd = try converter.point(plan.verticalCut.end)
        // Encode only the still-needed cuts and both names before any write.
        // Existing room metadata suffices for this preliminary syntax check.
        var preflight = [RoomMapOperation]()
        for step in plan.boxSteps ?? [] {
            if case .split(_, let line) = step.operation {
                preflight.append(.split(start: try converter.point(line.start), end: try converter.point(line.end),
                    leftRoomID: originalFirstID, rightRoomID: highestID + 1))
            }
        }
        if stage == .wholeArea {
            preflight.append(.split(start: horizontalStart, end: horizontalEnd,
                leftRoomID: originalFirstID, rightRoomID: highestID + 1))
        }
        if stage.splitCount > 0 {
            preflight.append(.split(start: verticalStart, end: verticalEnd,
                leftRoomID: originalFirstID, rightRoomID: highestID + stage.splitCount))
        }
        preflight += [.rename(roomID: originalFirstID, name: kitchenName), .rename(roomID: originalFirstID, name: hallwayName)]
        let validationUUID = String(repeating: "0", count: 32)
        _ = try NarwalCodec.roomOperationRequest(uuid: validationUUID, baseline: baseline, operations: preflight)
        await progress("Checking the saved map before editing…")
        var current = try await read()
        try RoomPartitionPlanner.validate(current: current, against: baseline)
        guard current.maximumRoomCount == baseline.maximumRoomCount else {
            throw ConnectorError.invalid("The robot’s room limit changed. Reload the map before saving.")
        }
        if stage == .finalPartitionSaved {
            let ids = try plan.recognizedFinalPartition(current.floorplan)
            if current.floorplan.rooms.first(where: { $0.id == ids[0] })?.name == kitchenName,
               current.floorplan.rooms.first(where: { $0.id == ids[1] })?.name == hallwayName {
                await progress("Saved room names verified; existing map cells preserved.")
                return current
            }
        }
        var attemptedWrite = false
        var completedSteps = 0
        var activeStep = "preparing the room edit"

        func nextRoomID(_ snapshot: MapSnapshot) throws -> Int {
            guard let highest = snapshot.floorplan.rooms.map(\.id).max(), highest < 255,
                  let limit = snapshot.maximumRoomCount, snapshot.floorplan.rooms.count < limit else {
                throw ConnectorError.invalid("The robot has no room slot available for another divider.")
            }
            return highest + 1
        }

        func perform(label: String, regions: [Set<Int>], renameNames: [Int: String]? = nil,
                     operations: (MapSnapshot) throws -> [RoomMapOperation]) async throws {
            activeStep = label
            try Task.checkCancellation()
            let fresh = try await read()
            try RoomPartitionPlanner.validate(current: fresh, against: current)
            guard fresh.maximumRoomCount == current.maximumRoomCount else {
                throw ConnectorError.invalid("The robot’s room limit changed. Inspect the current map before continuing.")
            }
            _ = try MapEditCoordinates(snapshot: fresh)
            let requested = try operations(fresh)
            _ = try NarwalCodec.roomOperationRequest(uuid: validationUUID, baseline: fresh, operations: requested)
            await progress(label)
            try Task.checkCancellation()
            attemptedWrite = true
            let result = try await apply(fresh, requested)
            let latest = result.snapshot
            // Preserve even a readback rejected by identity, opaque metadata or
            // geometry checks. An injected service may not keep its own copy.
            if let preserveReadback { try preserveReadback(latest) }
            else { _ = try MapSnapshotStore.preserveReadback(latest) }
            guard latest.productKey == fresh.productKey, latest.deviceID == fresh.deviceID,
                  latest.mapID == fresh.mapID, latest.mapVersion >= fresh.mapVersion,
                  latest.editVersion > fresh.editVersion else {
                throw ConnectorError.invalid("The robot did not return a newer matching saved map.")
            }
            let editedIDs = Set(requested.flatMap { operation -> [Int] in
                switch operation {
                case .split(_, _, let left, _): return [left]
                case .merge(let first, let second, _): return [first, second]
                case .rename(let id, _): return [id]
                }
            })
            let foreignMapping = plan.boxSteps == nil ? [:] :
                try plan.unchangedRoomMapping(from: baseline.floorplan, to: latest.floorplan,
                                               excluding: plan.sourceRoomIDs)
            let precedingMapping = plan.boxSteps == nil ? [:] :
                try plan.unchangedRoomMapping(from: fresh.floorplan, to: latest.floorplan,
                                               excluding: editedIDs)
            try NarwalCodec.validateRoomEditReadback(baseline: baseline, current: latest,
                                                    mutableRoomIDs: plan.sourceRoomIDs,
                                                    precedingSnapshot: fresh, operations: requested,
                                                    allowsGridRounding: plan.boxSteps != nil,
                                                    roomIDMapping: foreignMapping,
                                                    precedingRoomIDMapping: precedingMapping)
            if let renameNames {
                try NarwalCodec.validateRoomRenameReadback(baseline: fresh, current: latest, names: renameNames)
            }
            _ = try plan.validatePartition(regions: regions, latest: latest.floorplan)
            current = latest
            completedSteps += 1
        }

        do {
            for step in plan.boxSteps ?? [] {
                try await perform(label: "Applying the drawn room boundary…", regions: step.regions) { snapshot in
                    switch step.operation {
                    case .split(let region, let line):
                        let roomID = try plan.matchingRoomID(cells: region, in: snapshot.floorplan)
                        let points = try MapEditCoordinates(snapshot: snapshot)
                        return [.split(start: try points.point(line.start), end: try points.point(line.end),
                            leftRoomID: roomID, rightRoomID: try nextRoomID(snapshot))]
                    case .merge(let first, let second):
                        let firstID = try plan.matchingRoomID(cells: first, in: snapshot.floorplan)
                        let secondID = try plan.matchingRoomID(cells: second, in: snapshot.floorplan)
                        return [.merge(roomID1: firstID, roomID2: secondID, newRoomID: firstID)]
                    }
                }
            }
            if stage == .wholeArea && plan.sourceRoomIDs.count == 2 {
                try await perform(label: "Merging the selected rooms…", regions: [plan.sourceCells]) { _ in
                    let ids = plan.sourceRoomIDs.sorted()
                    return [.merge(roomID1: ids[0], roomID2: ids[1], newRoomID: ids[0])]
                }
            }
            if stage == .wholeArea {
                try await perform(label: "Saving the first divider…",
                    regions: [plan.horizontalRemainderCells, plan.cornerBandCells]) { snapshot in
                    let oldID = try plan.matchingRoomID(cells: plan.sourceCells, in: snapshot.floorplan)
                    let points = try MapEditCoordinates(snapshot: snapshot)
                    return [.split(start: try points.point(plan.horizontalCut.start), end: try points.point(plan.horizontalCut.end),
                                   leftRoomID: oldID, rightRoomID: try nextRoomID(snapshot))]
                }
            }
            if stage.splitCount > 0 {
                try await perform(label: "Saving the corner divider…",
                    regions: [plan.horizontalRemainderCells, plan.sideRemainderCells, plan.kitchenCells]) { snapshot in
                    let oldID = try plan.matchingRoomID(cells: plan.cornerBandCells, in: snapshot.floorplan)
                    let points = try MapEditCoordinates(snapshot: snapshot)
                    return [.split(start: try points.point(plan.verticalCut.start), end: try points.point(plan.verticalCut.end),
                                   leftRoomID: oldID, rightRoomID: try nextRoomID(snapshot))]
                }
            }
            if stage != .finalPartitionSaved && stage != .boxEdits {
                try await perform(label: "Joining the remaining sections…", regions: [plan.kitchenCells, plan.hallwayCells]) { snapshot in
                    let first = try plan.matchingRoomID(cells: plan.horizontalRemainderCells, in: snapshot.floorplan)
                    let second = try plan.matchingRoomID(cells: plan.sideRemainderCells, in: snapshot.floorplan)
                    return [.merge(roomID1: first, roomID2: second, newRoomID: first)]
                }
            }
            let nameIDs = try stage == .finalPartitionSaved
                ? plan.recognizedFinalPartition(current.floorplan) : plan.validateFinalPartition(current.floorplan)
            // Naming recovery freezes the actual saved footprints, not the
            // ideal all-cell rectangle used by geometry-write verification.
            let nameRegions = stage == .finalPartitionSaved ? nameIDs.map { id in
                Set(plan.sourceCells.filter { MapPixel(rawValue: current.floorplan.pixels[$0]).roomID == id })
            } : [plan.kitchenCells, plan.hallwayCells]
            let requestedNames = [nameIDs[0]: kitchenName, nameIDs[1]: hallwayName]
            try await perform(label: "Saving the room names…", regions: nameRegions, renameNames: requestedNames) { snapshot in
                let ids = try stage == .finalPartitionSaved
                    ? plan.recognizedFinalPartition(snapshot.floorplan) : plan.validateFinalPartition(snapshot.floorplan)
                guard ids == nameIDs else { throw ConnectorError.invalid("The saved room identifiers changed before naming.") }
                return [.rename(roomID: ids[0], name: kitchenName), .rename(roomID: ids[1], name: hallwayName)]
            }
            let finalIDs = try stage == .finalPartitionSaved
                ? plan.recognizedFinalPartition(current.floorplan) : plan.validateFinalPartition(current.floorplan)
            guard current.floorplan.rooms.first(where: { $0.id == finalIDs[0] })?.name == kitchenName,
                  current.floorplan.rooms.first(where: { $0.id == finalIDs[1] })?.name == hallwayName else {
                throw ConnectorError.invalid("The saved room names do not match the requested names.")
            }
            await progress(stage == .finalPartitionSaved
                ? "Saved room names verified; existing map cells preserved."
                : "Both rooms verified on the saved robot map.")
            return current
        } catch {
            if attemptedWrite {
                throw RoomPartitionTransactionError(completedSteps: completedSteps, stepLabel: activeStep,
                                                    detail: error.localizedDescription)
            }
            throw error
        }
    }
}
