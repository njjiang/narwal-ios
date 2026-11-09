import Foundation
import CoreFoundation

public struct RobotTimezone: Equatable, Sendable {
    public let identifier: String
    public let queryTimezone: String
    public let offsetSeconds: Int
    public var displayName: String { identifier.replacingOccurrences(of:"_",with:" ") }
    public init(identifier: String, queryTimezone: String, offsetSeconds: Int) {
        self.identifier=identifier; self.queryTimezone=queryTimezone; self.offsetSeconds=offsetSeconds
    }
}

public struct ScheduleContextSnapshot: Sendable {
    public let snapshot: ScheduleSnapshot
    public let map: MapSnapshot?
    public let timezone: RobotTimezone?
    public let queryTimezone: String
    public let primaryMapID: Int?
    public let deviceID: String
    public let productKey: String
    public var roomIDs: Set<Int> { Set(rooms.map(\.id)) }
    public var rooms: [RobotRoom] { map?.floorplan.rooms ?? [] }
    public var writeUnavailableReason: String? {
        if timezone == nil { return "The robot's timezone could not be verified. Schedules are read-only." }
        guard let map, let primaryMapID, primaryMapID == map.mapID else { return "The robot's primary map could not be verified. Schedules are read-only." }
        if rooms.isEmpty { return "Load rooms on the robot's primary map before changing a schedule." }
        return nil
    }
    public init(snapshot: ScheduleSnapshot, map: MapSnapshot?, timezone: RobotTimezone?, queryTimezone: String, primaryMapID: Int?, deviceID: String, productKey: String) {
        self.snapshot=snapshot; self.map=map; self.timezone=timezone; self.queryTimezone=queryTimezone; self.primaryMapID=primaryMapID; self.deviceID=deviceID; self.productKey=productKey
    }
}

public enum ScheduleWriteError: Error, LocalizedError, Sendable {
    case outcomeUnknown
    public var errorDescription: String? { "The schedule change could not be verified. It may have been saved. Refresh schedules before making another change." }
}

/// Pure, offline-testable guards around schedule context and one-shot writes.
enum RobotScheduleContext {
    static let timezonePath = "/device-extend-info-server/v1/app/device/location/query"

    static func timezoneRequest(device: RobotDevice) throws -> ScheduleRequest {
        guard device.canControl, device.id.range(of:#"^[a-fA-F0-9]{32}$"#,options:.regularExpression) != nil else { throw invalid("Choose a supported robot before reading its timezone.") }
        var parts=URLComponents(); parts.path=timezonePath
        // Official NRGetDeviceLocationTimezoneRequester uses optional timezone="".
        parts.queryItems=[URLQueryItem(name:"product_id",value:device.productKey),URLQueryItem(name:"device_id",value:device.id),URLQueryItem(name:"timezone",value:"")]
        guard let path=parts.string else { throw invalid("The robot timezone request is invalid.") }
        return ScheduleRequest(method:"GET",path:path)
    }

    static func timezone(_ data: Data, device: RobotDevice, now: Date = Date()) throws -> RobotTimezone {
        guard !data.isEmpty, data.count <= 64*1024,
              let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let code=root["code"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(), code.doubleValue == 0,
              let result=root["result"] as? [String:Any], result["device_id"] as? String == device.id,
              result["product_id"] as? String == device.productKey,
              let name=result["timezone"] as? String, name.utf8.count <= 128,
              name == "UTC" || name.contains("/"), let zone=TimeZone(identifier:name) else {
            throw invalid("Narwal did not return a verified timezone for this robot.")
        }
        let seconds=zone.secondsFromGMT(for:now)
        guard abs(seconds) <= 14*3600, seconds % 3600 == 0 else { throw invalid("This robot timezone needs an unsupported fractional-hour schedule query.") }
        return RobotTimezone(identifier:name,queryTimezone:queryOffset(seconds:seconds),offsetSeconds:seconds)
    }

    static func viewQueryTimezone(now: Date = Date(), local: TimeZone = .current) -> String {
        let seconds=local.secondsFromGMT(for:now)
        // The official query rounds its offset to whole hours. This fallback is
        // for list viewing only; it never grants timezone or mutation authority.
        return queryOffset(seconds:(seconds/3600)*3600)
    }

    static func primaryMapID(_ snapshot: MapSnapshot) throws -> Int? {
        // Official StaticMapPayload field30 isMainMap bool. Absent proto3 zero
        // means false; mapID1 alone is never evidence of a primary map.
        let fields=try NarwalCodec.fields(snapshot.staticMapPayload,limit:1024*1024,countLimit:10000)
        let value=try NarwalCodec.scalar(try NarwalCodec.one(fields,30),maximum:1) ?? 0
        return value == 1 ? snapshot.mapID : nil
    }

    static func validate(expected: ScheduleContextSnapshot, fresh: ScheduleContextSnapshot, device: RobotDevice) throws {
        guard expected.deviceID == device.id, expected.productKey == device.productKey,
              fresh.deviceID == device.id, fresh.productKey == device.productKey else { throw invalid("The schedule context belongs to a different robot.") }
        if let reason=fresh.writeUnavailableReason { throw invalid(reason) }
        guard expected.writeUnavailableReason == nil, expected.timezone == fresh.timezone,
              expected.primaryMapID == fresh.primaryMapID, let old=expected.map, let new=fresh.map,
              old.matches(device:device,mapID:old.mapID), new.matches(device:device,mapID:new.mapID),
              old.mapID == new.mapID, old.mapVersion == new.mapVersion, old.editVersion == new.editVersion,
              old.floorplan.width == new.floorplan.width, old.floorplan.height == new.floorplan.height,
              old.floorplan.resolution == new.floorplan.resolution,
              old.floorplan.rooms == new.floorplan.rooms, sameScheduleGeometry(old.floorplan.pixels,new.floorplan.pixels) else {
            throw invalid("The robot's map or timezone changed. Refresh schedules and review the settings again.")
        }
    }

    static func currentEntry(_ expected: ScheduleEntry, in context: ScheduleContextSnapshot) throws -> ScheduleEntry {
        guard let actual=context.snapshot.entries.first(where:{$0.id == expected.id}), actual.originalJSON == expected.originalJSON else {
            throw invalid("This schedule changed or was removed. Refresh schedules before editing it.")
        }
        guard actual.canEdit, let ids=actual.roomIDs, !ids.isEmpty, Set(ids).isSubset(of:context.roomIDs) else {
            throw invalid(actual.supportedEditReason ?? "This schedule targets rooms that no longer exist.")
        }
        return actual
    }

    static func validateUnchangedSchedules(before: ScheduleContextSnapshot, after: ScheduleContextSnapshot, changedKey: String) throws {
        guard Set(before.snapshot.entries.map(\.id)).count == before.snapshot.entries.count,
              Set(after.snapshot.entries.map(\.id)).count == after.snapshot.entries.count else { throw invalid("The schedule list contains duplicate identifiers.") }
        let old=Dictionary(uniqueKeysWithValues:before.snapshot.entries.filter{$0.id != changedKey}.map{($0.id,$0.originalJSON)})
        let new=Dictionary(uniqueKeysWithValues:after.snapshot.entries.filter{$0.id != changedKey}.map{($0.id,$0.originalJSON)})
        guard old == new else { throw invalid("Other schedules changed while saving. Refresh the list before continuing.") }
    }
    private static func sameScheduleGeometry(_ a:[UInt32],_ b:[UInt32]) -> Bool {
        guard a.count == b.count else { return false }
        // Runtime bits observed changing in the prior live route captures,
        // matching CleaningHistoryStore. This comparison does not write maps. Room IDs, walls,
        // unreachable flags and every other bit remain exact.
        let runtimeMask:UInt32=0x1001_0043
        return zip(a,b).allSatisfy{($0 ^ $1) & ~runtimeMask == 0}
    }

    /// No automatic retry: even failed acknowledgement/readback can follow an
    /// applied write. The service latches this state until an explicit refresh.
    static func commit(send: () async throws -> Data, readBack: () async throws -> ScheduleContextSnapshot,
                       verify: (ScheduleContextSnapshot) throws -> Void) async throws -> ScheduleContextSnapshot {
        do {
            try NarwalScheduleCodec.acknowledgement(try await send())
            let current=try await readBack()
            try verify(current)
            return current
        } catch { throw ScheduleWriteError.outcomeUnknown }
    }
    private static func queryOffset(seconds:Int) -> String { "UTC" + (seconds >= 0 ? "+" : "") + String(seconds/3600) }
    private static func invalid(_ message:String) -> ConnectorError { .invalid(message) }
}
