import Foundation

public enum CleaningMode: String, CaseIterable, Identifiable, Sendable {
    case vacuum, mop, vacuumMop, vacuumThenMop
    public var id: String { rawValue }
    public var title: String {
        switch self { case .vacuum: return "Vacuum"; case .mop: return "Mop"; case .vacuumMop: return "Vacuum & mop"; case .vacuumThenMop: return "Vacuum, then mop" }
    }
    public var symbol: String {
        switch self { case .vacuum: return "wind"; case .mop: return "drop"; case .vacuumMop: return "drop.circle"; case .vacuumThenMop: return "arrow.right" }
    }
}
public enum RobotAction: String, Sendable { case start, pause, resume, dock }
public struct RobotDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let productKey: String
    public let name: String
    public let firmware: String?
    public let serialSuffix: String?
    public var canControl: Bool { productKey == "EHf6cRNRGT" }
    public init(id: String, productKey: String, name: String, firmware: String? = nil, serialSuffix: String? = nil) { self.id=id; self.productKey=productKey; self.name=name; self.firmware=firmware; self.serialSuffix=serialSuffix }
}
public struct RobotStatus: Sendable {
    public let battery: Double?
    /// Raw field 3.1. Its meaning differs across model/firmware observations.
    public let workingCode: Int?
    /// Explicit field 3.2; absence is not evidence that a task is running.
    public let isPaused: Bool?
    /// Exact RobotBaseStatus field 11, independent of the task-state enum.
    public let stationContactCode: Int?
    /// Exact RobotBaseStatus field 26 (FanLevel), not the requested task setting
    /// or a measurement of acoustic noise. Unfamiliar codes remain unlabeled.
    public let reportedSuctionCode: Int?
    public let updatedAt: Date
    private var simulatedLabel: String?
    public init(battery: Double?, workingCode: Int?, isPaused: Bool? = nil, stationContactCode: Int? = nil, reportedSuctionCode: Int? = nil, updatedAt: Date = Date()) {
        self.battery=battery; self.workingCode=workingCode; self.isPaused=isPaused; self.stationContactCode=stationContactCode; self.reportedSuctionCode=reportedSuctionCode; self.updatedAt=updatedAt
    }
    public var reportedSuction: CleaningSuction? { reportedSuctionCode.flatMap(CleaningSuction.init(rawValue:)) }
    public var reportedSuctionLabel: String? { reportedSuction?.title }
    public var stationContactLabel: String? {
        switch stationContactCode { case 1: return "Away from dock"; case 2: return "Dock contact"; case 3: return "Charging contact"; default: return nil }
    }
    public var label: String {
        if let simulatedLabel { return simulatedLabel }
        if isPaused == true { return "Paused" }
        // Only code 1 has been checked against this Freo X Ultra. The compiled
        // app TaskType enum conflicts with live observations on other firmware;
        // in particular, code 2 alone cannot establish pause or dock presence.
        guard let workingCode else { return "Unavailable" }
        return workingCode == 1 ? "Standby" : "State \(workingCode)"
    }
    /// UI-only simulation; these codes must never label a live response.
    public static func simulated(battery: Double?, workingCode: Int, updatedAt: Date = Date()) -> RobotStatus {
        var result = RobotStatus(battery: battery, workingCode: workingCode, isPaused: workingCode == 2, updatedAt: updatedAt)
        result.simulatedLabel = [0:"Unknown",1:"Standby",2:"Paused",3:"Sleeping",4:"Cleaning",5:"Cleaning",6:"Returning",7:"Charging",8:"Washing mops",9:"Drying mops",10:"Docked",11:"Collecting dust",12:"Updating firmware",13:"Self-check",14:"Charged",99:"Error"][workingCode] ?? "Unknown"
        return result
    }
}
public struct RobotRoom: Identifiable, Equatable, Codable, Sendable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) { self.id=id; self.name=name }
}
public struct Floorplan: Equatable, Codable, Sendable {
    public let mapID: Int
    public let width: Int
    public let height: Int
    public let resolution: Int?
    public let rooms: [RobotRoom]
    public let pixels: [UInt32]
    public let mapRevision: UInt32?
    /// Metadata can retain deleted room IDs after a split/merge. Only rooms
    /// assigned actual cells belong in cleaning choices and Siri's catalog.
    public var roomsWithArea: [RobotRoom] {
        guard width > 0, height > 0, width <= Int.max / height,
              pixels.count == width * height else { return rooms }
        let present = Set(pixels.map { MapPixel(rawValue: $0).roomID })
        return rooms.filter { present.contains($0.id) }
    }
    public init(mapID: Int, width: Int, height: Int, resolution: Int?, rooms: [RobotRoom], pixels: [UInt32], mapRevision: UInt32? = nil) { self.mapID=mapID; self.width=width; self.height=height; self.resolution=resolution; self.rooms=rooms; self.pixels=pixels; self.mapRevision=mapRevision }
}
/// An exact, scoped read of the saved map. No restore protocol is implemented,
/// so this is a snapshot rather than a promise of a restorable backup.
public struct MapSnapshot: Sendable {
    public let productKey: String
    public let deviceID: String
    public let mapID: Int
    public let mapVersion: UInt32
    public let editVersion: UInt32
    public let capturedAt: Date
    public let floorplan: Floorplan
    /// Exact StaticMapPayload bytes, excluding account and response envelopes.
    /// Unknown fields and their ordering are preserved; never log this payload.
    public let staticMapPayload: Data
    /// Present only when the editable-map response supplies its room limit.
    public internal(set) var maximumRoomCount: Int? = nil

    public func matches(device: RobotDevice, mapID: Int) -> Bool {
        productKey == device.productKey && deviceID == device.id && self.mapID == mapID
    }
}
public struct MapEditPoint: Equatable, Sendable {
    public let x: Float
    public let y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}
/// Coordinates and side IDs must come from the verified map geometry planner.
/// Renaming uses metadata from the current snapshot; new rooms need a readback.
public enum RoomMapOperation: Sendable {
    case split(start: MapEditPoint, end: MapEditPoint, leftRoomID: Int, rightRoomID: Int)
    case merge(roomID1: Int, roomID2: Int, newRoomID: Int)
    case rename(roomID: Int, name: String)
}
public struct MapEditAcknowledgement: Sendable {
    public let resultCode: Int
    public let errorCode: Int?
    public let unifiedErrorCode: Int?
    public let editVersion: UInt32?
    public var accepted: Bool { resultCode == 1 && (errorCode ?? 0) == 0 && (unifiedErrorCode ?? 0) == 0 }
}
/// Geometry must be verified against snapshot before the UI says the edit saved.
/// acknowledged=false means the send had an unknown outcome and only a newer
/// readback was obtained. A different app may have changed the map meanwhile.
public struct MapEditCommitResult: Sendable {
    public let acknowledged: Bool
    public let snapshot: MapSnapshot
    public let preservedSnapshotURL: URL
}
public enum MapEditError: LocalizedError, Sendable {
    case staleSnapshot
    case rejected(result: Int, code: Int?, unifiedCode: Int?)
    case outcomeUnknown
    public var errorDescription: String? {
        switch self {
        case .staleSnapshot: return "The saved map changed. Reload it and review the room edits again. Nothing was sent."
        case .rejected(let result, let code, let unified):
            if code == 1 { return "Narwal rejected the edit because the map version changed. Reload the map before trying again." }
            if code == 3 { return "Narwal rejected an intermediate split because one piece was smaller than 0.5 m². The requested final room may be larger. Reload the saved pieces before adjusting the box." }
            if code == 5 || code == 101 { return "Narwal could not apply this divider to the saved room. Reload the map and review the box against its current boundaries (error \(code ?? 0))." }
            return "Narwal rejected the room edit (result \(result), error \(code ?? 0), detail \(unified ?? 0)). Reload the map to check its current state."
        case .outcomeUnknown: return "The map edit may have reached the robot, but its saved result could not be verified. Reload the map before making another edit. No automatic retry was made."
        }
    }
}
public struct RoomMap: Sendable {
    public let mapID: Int?
    public let rooms: [RobotRoom]
    public let mapRevision: UInt32?
    public init(mapID: Int?, rooms: [RobotRoom], mapRevision: UInt32? = nil) { self.mapID=mapID; self.rooms=rooms; self.mapRevision=mapRevision }
}
public struct CleaningTaskSample: Sendable {
    public let roomID: Int?
    public let parameters: [Int: UInt64]
    public init(roomID: Int?, parameters: [Int: UInt64]) { self.roomID=roomID; self.parameters=parameters }
}
public struct CleaningTaskSnapshot: Sendable {
    public let resultCode: Int
    public let mapID: Int?
    public let taskType: Int?
    public let optionFields: [Int: UInt64]
    public let samples: [CleaningTaskSample]
    public init(resultCode: Int, mapID: Int?, taskType: Int?, optionFields: [Int: UInt64], samples: [CleaningTaskSample]) { self.resultCode=resultCode; self.mapID=mapID; self.taskType=taskType; self.optionFields=optionFields; self.samples=samples }
}
/// Conservative gate for replacing a running clean. Only a documented idle
/// readback allows a start; an active task requires recall and a fresh idle
/// readback before the replacement can be sent.
public enum TaskReplacementPolicy {
    public enum Initial: Equatable { case ready, recall, uncertain }
    public enum AfterRecall: Equatable { case ready, waiting, uncertain }

    public static func initial(status: RobotStatus, plan: CleaningTaskSnapshot) -> Initial {
        if hasActiveTask(plan) { return .recall }
        return isIdle(status: status, plan: plan) ? .ready : .uncertain
    }

    public static func afterRecall(status: RobotStatus, plan: CleaningTaskSnapshot) -> AfterRecall {
        if isIdle(status: status, plan: plan) { return .ready }
        if hasActiveTask(plan) { return .waiting }
        if isEmptyPlan(plan), status.workingCode != nil { return .waiting }
        return .uncertain
    }

    private static func hasActiveTask(_ plan: CleaningTaskSnapshot) -> Bool {
        plan.resultCode == 1 && !plan.samples.isEmpty
    }

    private static func isEmptyPlan(_ plan: CleaningTaskSnapshot) -> Bool {
        plan.resultCode == 2 && plan.samples.isEmpty
    }

    private static func isIdle(status: RobotStatus, plan: CleaningTaskSnapshot) -> Bool {
        isEmptyPlan(plan) && status.workingCode == 1 && status.isPaused != true
    }
}
public struct CommandAcknowledgement: Sendable {
    public let accepted: Bool
    public let resultCode: Int
    public init(accepted: Bool, resultCode: Int) { self.accepted=accepted; self.resultCode=resultCode }
}
public enum ConnectorError: LocalizedError, Sendable {
    case invalid(String)
    case outcomeUnknown
    public var errorDescription: String? {
        switch self { case .invalid(let text): return text; case .outcomeUnknown: return "The command may have reached the robot, but its result is unknown. Check status before sending another command. No automatic retry was made." }
    }
}
