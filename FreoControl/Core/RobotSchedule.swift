import Foundation

/// A bounded view of the cloud schedule list. Robot time is not the phone's time.
public struct ScheduleSnapshot: Sendable {
    public let entries: [ScheduleEntry]
    public let fetchedAt: Date
    public let timezone: String?
    public let unsupportedReason: String?
    public init(entries: [ScheduleEntry], fetchedAt: Date = Date(), timezone: String? = nil, unsupportedReason: String? = nil) {
        self.entries = entries; self.fetchedAt = fetchedAt; self.timezone = timezone; self.unsupportedReason = unsupportedReason
    }
}

public struct ScheduleEntry: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool?
    public let hour: Int?
    public let minute: Int?
    /// ISO weekdays: Monday 1 through Sunday 7. Nil means an unsupported recurrence.
    public let weekdays: [Int]?
    public let mode: CleaningMode?
    public let roomIDs: [Int]?
    public let mapID: Int?
    public let cron: String
    public let supportedEditReason: String?
    /// Full entry, including unrecognized options. Never send a reconstructed display model.
    public let originalJSON: Data
    public var canEdit: Bool { supportedEditReason == nil }
    public init(id: String, name: String, enabled: Bool?, hour: Int?, minute: Int?, weekdays: [Int]?, mode: CleaningMode?, roomIDs: [Int]?, mapID: Int?, cron: String, supportedEditReason: String?, originalJSON: Data) {
        self.id=id; self.name=name; self.enabled=enabled; self.hour=hour; self.minute=minute; self.weekdays=weekdays; self.mode=mode; self.roomIDs=roomIDs; self.mapID=mapID; self.cron=cron; self.supportedEditReason=supportedEditReason; self.originalJSON=originalJSON
    }
}

/// Weekly local robot time. Editing a schedule retains its complete cleaning task.
public struct ScheduleDraft: Sendable {
    public var name: String
    public var enabled: Bool
    public var hour: Int
    public var minute: Int
    public var weekdays: [Int]
    public var mode: CleaningMode
    public var roomIDs: [Int]
    public var mapID: Int?
    public init(name: String = "Scheduled cleaning", enabled: Bool = true, hour: Int = 9, minute: Int = 0, weekdays: [Int] = [1,2,3,4,5,6,7], mode: CleaningMode = .vacuum, roomIDs: [Int] = [], mapID: Int? = nil) {
        self.name=name; self.enabled=enabled; self.hour=hour; self.minute=minute; self.weekdays=weekdays; self.mode=mode; self.roomIDs=roomIDs; self.mapID=mapID
    }
    public init(entry: ScheduleEntry) {
        self.init(name: entry.name, enabled: entry.enabled ?? false, hour: entry.hour ?? 9, minute: entry.minute ?? 0, weekdays: entry.weekdays ?? [], mode: entry.mode ?? .vacuum, roomIDs: entry.roomIDs ?? [], mapID: entry.mapID)
    }
}

public struct ScheduleRequest: Sendable {
    public let method: String
    public let path: String
    public let body: Data?
    public init(method: String, path: String, body: Data? = nil) { self.method=method; self.path=path; self.body=body }
}
