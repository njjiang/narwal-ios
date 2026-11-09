import Foundation

/// Targets reported by the robot's current task, independent of UI selections.
/// A target room is not proof that the robot is physically cleaning there now.
public struct CurrentCleaningTask: Equatable, Sendable {
    public let rooms: [RobotRoom]
    public let modeNames: [String]
    public let unresolvedRoomIDs: [Int]
    public let hasUnknownRoomTargets: Bool

    /// The caller supplies the current room catalog for the same robot and map.
    /// No task or catalog timestamps are available in this wire model, so the
    /// caller remains responsible for fetching and expiring those observations.
    public static func resolve(plan: CleaningTaskSnapshot, rooms catalog: [RobotRoom],
                               mapID: Int) -> CurrentCleaningTask? {
        guard plan.resultCode == 1, mapID > 0, plan.mapID == mapID,
              !plan.samples.isEmpty, validCatalog(catalog) else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        var rooms: [RobotRoom] = [], unresolved: [Int] = [], modes: [String] = []
        var seenIDs = Set<Int>(), seenModes = Set<String>(), missingTarget = false
        for sample in plan.samples {
            if let id = sample.roomID {
                if seenIDs.insert(id).inserted {
                    if let room = byID[id] { rooms.append(room) }
                    else { unresolved.append(id) }
                }
            } else { missingTarget = true }
            let mode: String
            switch sample.parameters[1] {
            case 2: mode = CleaningMode.vacuum.title
            case 3: mode = CleaningMode.mop.title
            case 4: mode = CleaningMode.vacuumMop.title
            case 5: mode = CleaningMode.vacuumThenMop.title
            case .some(let code): mode = "Unknown mode (\(code))"
            case .none: mode = "Unknown mode"
            }
            if seenModes.insert(mode).inserted { modes.append(mode) }
        }
        return CurrentCleaningTask(rooms: rooms, modeNames: modes,
            unresolvedRoomIDs: unresolved, hasUnknownRoomTargets: missingTarget || !unresolved.isEmpty)
    }

    /// A fresh pose can locate the robot's room; this does not infer whether its
    /// motors are cleaning. A route tail has no per-point timestamp and is never
    /// substituted for a missing pose, including on a newly received old route.
    public static func positionRoom(floorplan: Floorplan, trajectory: RobotTrajectory,
                                    now: Date) -> RobotRoom? {
        guard !trajectory.isSimulated, floorplan.mapID > 0,
              trajectory.mapID == floorplan.mapID,
              let revision = floorplan.mapRevision, trajectory.editVersion == revision,
              let timestamp = trajectory.deviceTimestampMilliseconds,
              let point = trajectory.pose?.point,
              fresh(trajectory.capturedAt, now: now),
              fresh(Date(timeIntervalSince1970: Double(timestamp) / 1_000), now: now),
              floorplan.width > 0, floorplan.height > 0,
              floorplan.width <= 1_000_000 / floorplan.height,
              floorplan.pixels.count == floorplan.width * floorplan.height,
              validCatalog(floorplan.rooms), point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x < Double(floorplan.width), point.y < Double(floorplan.height) else { return nil }
        // Pose is already in top-left display coordinates. Stored raster rows
        // are bottom-up; perform this conversion exactly once, without clamping.
        let column = Int(point.x), row = floorplan.height - 1 - Int(point.y)
        let id = MapPixel(rawValue: floorplan.pixels[row * floorplan.width + column]).roomID
        return floorplan.rooms.first { $0.id == id }
    }

    private static func fresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age.isFinite && age >= 0 && age <= 30
    }

    private static func validCatalog(_ rooms: [RobotRoom]) -> Bool {
        rooms.allSatisfy { (1...255).contains($0.id) } && Set(rooms.map(\.id)).count == rooms.count
    }
}
