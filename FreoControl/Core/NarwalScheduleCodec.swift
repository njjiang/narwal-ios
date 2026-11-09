import Foundation
import CoreFoundation

/// Original codec from the signed official 2.10.90 app's TimingService,
/// TimingTaskAdditionalRequester, ScheduledCleaningTask and CronUtil descriptors.
/// It makes no network requests. Transport authorization and readback are separate.
public enum NarwalScheduleCodec {
    public static let listPath = "/sweeper-schedule-app-server/v2/schedule/getScheduleTaskList"
    public static let additionalPath = "/device-task/scheduled-task/sweeper/additional"
    public static let deletePath = "/device-task/scheduled-task/sweeper/deleteEntry"
    private static let limit = 1024 * 1024

    public static func listRequest(device: RobotDevice, timezone: String) throws -> ScheduleRequest {
        try validateDevice(device)
        // Official query uses a UTC-offset label, not an IANA timezone identifier.
        guard timezone.range(of: #"^UTC[+-](?:[0-9]|1[0-4])$"#, options: .regularExpression) != nil else { throw invalid("The schedule query timezone is invalid.") }
        var components = URLComponents(); components.path = listPath
        components.queryItems = [URLQueryItem(name: "device_id", value: device.id), URLQueryItem(name: "product_id", value: device.productKey), URLQueryItem(name: "timezone", value: timezone)]
        // Form-style query decoders otherwise interpret a literal plus as space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let path = components.string else { throw invalid("The schedule query is invalid.") }
        return ScheduleRequest(method: "GET", path: path)
    }

    public static func list(_ data: Data, timezone: String? = nil, primaryMapID: Int? = nil, fetchedAt: Date = Date()) throws -> ScheduleSnapshot {
        let root = try object(data)
        guard successCode(root["code"]), let result = root["result"] as? [String: Any] else { throw invalid("Narwal did not return a recognized schedule list.") }
        // A missing collection is not proof that the robot has no schedules.
        guard let tasks = result["scheduled_cleaning_tasks"] as? [String: Any], tasks.count <= 100 else { throw invalid("The cleaning schedule collection is missing or too large.") }
        let entries = try tasks.keys.sorted().map { id -> ScheduleEntry in
            try validateKey(id)
            guard let raw = tasks[id] as? [String: Any] else { throw invalid("A cleaning schedule has an invalid shape.") }
            return try entry(id: id, raw: raw, primaryMapID: primaryMapID)
        }
        return ScheduleSnapshot(entries: entries, fetchedAt: fetchedAt, timezone: timezone,
            unsupportedReason: timezone == nil ? "Read the robot's timezone before changing a schedule." : nil)
    }

    /// Generates only the independently verified weekly Quartz subset. ISO days
    /// are converted explicitly: official numeric cron Sunday=1, Monday=2.
    public static func weeklyCron(hour: Int, minute: Int, weekdays: [Int]) throws -> String {
        guard (0...23).contains(hour), (0...59).contains(minute), !weekdays.isEmpty,
              weekdays.count <= 7, Set(weekdays).count == weekdays.count,
              weekdays.allSatisfy({ (1...7).contains($0) }) else { throw invalid("Choose a valid time and at least one distinct weekday.") }
        let names = [1:"MON", 2:"TUE", 3:"WED", 4:"THU", 5:"FRI", 6:"SAT", 7:"SUN"]
        return "0 \(minute) \(hour) ? * " + weekdays.sorted().map { names[$0]! }.joined(separator: ",")
    }

    public static func parseWeeklyCron(_ cron: String) -> (hour: Int, minute: Int, weekdays: [Int])? {
        guard cron.utf8.count <= 128 else { return nil }
        let parts = cron.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 6, parts[0] == "0", parts[3] == "?", parts[4] == "*",
              let minute = Int(parts[1]), (0...59).contains(minute), let hour = Int(parts[2]), (0...23).contains(hour) else { return nil }
        let aliases = ["MON":1,"TUE":2,"WED":3,"THU":4,"FRI":5,"SAT":6,"SUN":7,"1":7,"2":1,"3":2,"4":3,"5":4,"6":5,"7":6]
        let terms = parts[5].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !terms.isEmpty, terms.count <= 7 else { return nil }
        var days = [Int]()
        for term in terms { guard let value = aliases[term], !days.contains(value) else { return nil }; days.append(value) }
        return (hour, minute, days.sorted())
    }

    /// Payload preparation is deliberately separate from HTTP method selection.
    /// All unedited fields (including task settings, exception dates and extra)
    /// are preserved. Service must verify method, robot timezone and fresh scope.
    public static func updateBody(entry: ScheduleEntry, draft: ScheduleDraft, device: RobotDevice, primaryMapID: Int) throws -> Data {
        var raw = try editable(entry, primaryMapID: primaryMapID)
        guard draft.name == entry.name, draft.mode == entry.mode, draft.roomIDs == entry.roomIDs, draft.mapID == entry.mapID else {
            throw invalid("This editor can change schedule time, weekdays and enabled state only.")
        }
        let cron = try weeklyCron(hour: draft.hour, minute: draft.minute, weekdays: draft.weekdays)
        raw["cron"] = cron
        if var task = raw["task"] as? [String: Any], let extra = task["extra"] as? String, !extra.isEmpty {
            var metadata = try object(Data(extra.utf8))
            guard metadata["cron"] as? String == entry.cron else { throw invalid("The schedule metadata and recurrence disagree. Refresh it in the Narwal app.") }
            metadata["cron"] = cron
            task["extra"] = String(decoding: try encode(metadata), as: UTF8.self)
            raw["task"] = task
        }
        raw["enable"] = draft.enabled
        return try additionalBody(id: entry.id, raw: raw, device: device)
    }

    public static func setEnabledBody(entry: ScheduleEntry, enabled: Bool, device: RobotDevice, primaryMapID: Int) throws -> Data {
        var raw = try editable(entry, primaryMapID: primaryMapID)
        raw["enable"] = enabled
        return try additionalBody(id: entry.id, raw: raw, device: device)
    }

    /// Prepare one new weekly room schedule. The caller must retain the key for
    /// readback and must never generate another key to retry an uncertain write.
    public static func createBody(draft: ScheduleDraft, device: RobotDevice, primaryMapID: Int, knownRoomIDs: Set<Int>, key: String, now: Date = Date()) throws -> Data {
        try validateDevice(device); try validateKey(key)
        let uuid = UUID(uuidString:key)!.uuid
        guard uuid.6 >> 4 == 1, uuid.8 & 0xc0 == 0x80 else { throw invalid("A new schedule needs one stable version-1 identifier.") }
        guard primaryMapID > 0, primaryMapID <= Int(Int32.max), draft.mapID == primaryMapID,
              !draft.roomIDs.isEmpty, draft.roomIDs.count <= 100,
              Set(draft.roomIDs).count == draft.roomIDs.count,
              draft.roomIDs.allSatisfy({ $0 > 0 && $0 <= 255 && knownRoomIDs.contains($0) }) else {
            throw invalid("Choose rooms from a fresh read of the primary map before scheduling.")
        }
        let title=draft.name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 64, !title.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw invalid("Choose a schedule name of 1–64 characters.") }
        let cron=try weeklyCron(hour:draft.hour,minute:draft.minute,weekdays:draft.weekdays)
        var parameter:[String:Any] = ["fanLevel":2,"mopStrengthLevel":1,"mopHumidity":2,"overlapLevel":1]
        switch draft.mode {
        case .vacuum: parameter["mode"]="CLEAN_MODE_SWEEP"; parameter["sweepTime"]=1
        case .mop: parameter["mode"]="CLEAN_MODE_MOP"; parameter["mopTime"]=1
        case .vacuumMop: parameter["mode"]="CLEAN_MODE_SWEEP_MOP_SYNC"; parameter["sweepMopSyncTime"]=1
        case .vacuumThenMop: parameter["mode"]="CLEAN_MODE_SWEEP_THEN_MOP"; parameter["sweepTime"]=1; parameter["mopTime"]=1
        }
        let millis=try epochMilliseconds(now)
        // Official direct-task creation builds a CleanTaskModel with a scheme
        // and created/updated milliseconds; nullable shortcut/cloud IDs stay nil.
        // TimingTaskKeyGenerator omits the nested cleanTask to avoid recursion.
        let metadata:[String:Any] = ["cron":cron,"task":[
            "id":NSNull(),"sweeper_scheme_task":["taskName":title],
            "product_id":NSNull(),"device_id":NSNull(),"is_has_station":NSNull(),
            "bind_schedule_task_ids":NSNull(),"created_at":millis,
            "map_generate_time":NSNull(),"map_id":NSNull(),"updated_at":millis,"sort_order":NSNull()
        ]]
        let task:[String:Any] = ["mapId":primaryMapID,"items":draft.roomIDs.enumerated().map { index, room in
            ["zone":["zoneType":"ZONE_TYPE_ROOM","zoneId":room],"param":parameter,"order":index+1] as [String:Any]
        },"option":[:],"taskType":"TASK_TYPE_SCHEDULED","extra":String(decoding:try encode(metadata),as:UTF8.self)]
        return try additionalBody(id:key,raw:["task":task,"cron":cron,"enable":draft.enabled,"triggerType":"SCHEDULE_TRIGGER_TYPE_CRON"],device:device)
    }

    /// The official app uses UUID v1. A random multicast node avoids encoding a
    /// hardware identifier. Clock sequence and node come from system UUID entropy.
    public static func newKey(now: Date = Date(), entropy: UUID = UUID()) throws -> String {
        let milliseconds=try epochMilliseconds(now)
        let ticks=UInt64(milliseconds) * 10_000 + 0x01b21dd213814000
        let random=entropy.uuid
        let sequence=(UInt16(random.8) << 8 | UInt16(random.9)) & 0x3fff
        let node:[UInt8] = [random.10 | 1,random.11,random.12,random.13,random.14,random.15]
        let uuid:uuid_t=(UInt8(truncatingIfNeeded:ticks >> 24),UInt8(truncatingIfNeeded:ticks >> 16),UInt8(truncatingIfNeeded:ticks >> 8),UInt8(truncatingIfNeeded:ticks),
            UInt8(truncatingIfNeeded:ticks >> 40),UInt8(truncatingIfNeeded:ticks >> 32),UInt8(truncatingIfNeeded:(ticks >> 56) & 0x0f) | 0x10,UInt8(truncatingIfNeeded:ticks >> 48),
            UInt8(sequence >> 8) | 0x80,UInt8(truncatingIfNeeded:sequence),node[0],node[1],node[2],node[3],node[4],node[5])
        return UUID(uuid:uuid).uuidString.lowercased()
    }

    public static func delete(entry: ScheduleEntry, device: RobotDevice) throws -> ScheduleRequest {
        try validateDevice(device); try validateKey(entry.id)
        return ScheduleRequest(method: "POST", path: deletePath, body: try encode([
            "device_id": device.id, "product_id": device.productKey, "scheduled_cleaning_tasks_key": entry.id
        ]))
    }

    public static func acknowledgement(_ data: Data) throws {
        guard successCode(try object(data)["code"]) else { throw invalid("Narwal did not accept the schedule request.") }
        // Acceptance is not an applied schedule: the service must fetch and compare.
    }

    public static func validateReadback(expectedBody: Data, current: ScheduleSnapshot) throws {
        let body = try object(expectedBody)
        guard let tasks = body["scheduled_cleaning_tasks"] as? [String: Any], tasks.count == 1,
              let (id, expected) = tasks.first, let expected = expected as? [String: Any],
              let actual = current.entries.first(where: { $0.id == id }),
              try encode(readbackDefaults(expected)) == encode(readbackDefaults(object(actual.originalJSON))) else {
            throw invalid("The saved schedule does not exactly match the requested settings. Refresh before trying again.")
        }
    }

    private static func entry(id: String, raw: [String: Any], primaryMapID: Int?) throws -> ScheduleEntry {
        let original = try encode(raw)
        guard original.count <= 64 * 1024 else { throw invalid("A schedule is too large to preserve safely.") }
        let cron = raw["cron"] as? String ?? ""
        guard cron.utf8.count <= 1024 else { throw invalid("The schedule recurrence is too long.") }
        let timing = parseWeeklyCron(cron)
        let enabled: Bool? = raw["enable"] == nil ? false : bool(raw["enable"])
        var reason: String?
        let triggerValue = try alias(raw, "triggerType", "trigger_type")
        let trigger = try enumNumber(triggerValue, names: ["SCHEDULE_TRIGGER_TYPE_UNSPECIFIED":0,"SCHEDULE_TRIGGER_TYPE_CRON":1,"SCHEDULE_TRIGGER_TYPE_CYCLE":2])
        if timing == nil { reason = "This recurrence can be viewed but is not supported by the editor." }
        if triggerValue != nil && trigger != 0 && trigger != 1 { reason = "This schedule trigger is read-only in this app." }
        if enabled == nil { reason = "The schedule enabled state is not recognized." }
        // Changing a weekly time with per-date exceptions can change the meaning
        // of those exceptions. Preserve and show these entries read-only.
        for (camel, snake) in [("disabledCron","disabled_cron"),("enabledCron","enabled_cron")] {
            if let value = try alias(raw, camel, snake) {
                guard let values = value as? [String], values.count <= 100, values.allSatisfy({ $0.utf8.count <= 128 }) else { throw invalid("Schedule exception dates are invalid.") }
                if !values.isEmpty { reason = "Schedules with exception dates are read-only in this app." }
            }
        }
        var mapID: Int?, roomIDs: [Int]?, mode: CleaningMode?, name = "Scheduled cleaning"
        if let task = raw["task"] as? [String: Any] {
            mapID = try number(try alias(task,"mapId","map_id"))
            if let items = task["items"] as? [[String: Any]], !items.isEmpty, items.count <= 100 {
                var rooms = [Int](), modes = Set<String>(), valid = true
                for item in items {
                    guard let zone = item["zone"] as? [String: Any],
                          try enumNumber(try alias(zone,"zoneType","zone_type"), names: ["ZONE_TYPE_ROOM":1]) == 1,
                          let room = try number(try alias(zone,"zoneId","zone_id")), room > 0, room <= 255,
                          let param = item["param"] as? [String: Any] else { valid = false; continue }
                    rooms.append(room)
                    let value = try enumNumber(param["mode"], names: ["CLEAN_MODE_SWEEP":2,"CLEAN_MODE_MOP":3,"CLEAN_MODE_SWEEP_MOP_SYNC":4,"CLEAN_MODE_SWEEP_THEN_MOP":5])
                    if let cleanMode = modeFor(value) { modes.insert(cleanMode.rawValue) } else { valid = false }
                }
                if valid, Set(rooms).count == rooms.count { roomIDs=rooms; if modes.count == 1 { mode=CleaningMode(rawValue: modes.first!) } }
                else { reason = "Only existing room-based cleaning schedules can be edited." }
                if modes.count > 1 { reason = "Schedules with different cleaning modes per room are read-only." }
            } else { reason = "The cleaning target is not recognized." }
            for (camel,snake) in [("maintainFloorItems","maintain_floor_items"),("excludedRoomIds","excluded_room_ids")] {
                if let value = try alias(task,camel,snake) {
                    guard let values=value as? [Any], values.count <= 100 else { throw invalid("The schedule has invalid additional cleaning targets.") }
                    if !values.isEmpty { reason = "Schedules with additional cleaning targets are read-only." }
                }
            }
            if let extra = task["extra"] as? String, extra.utf8.count <= 32 * 1024,
               let bytes = extra.data(using: .utf8), let metadata = try? object(bytes),
               let model = metadata["task"] as? [String: Any],
               let scheme = model["sweeper_scheme_task"] as? [String: Any], let title = scheme["taskName"] as? String,
               !title.isEmpty, title.count <= 64 { name=title }
        } else { reason = "The schedule cleaning settings are missing." }
        if mapID == nil || mapID! <= 0 || mapID != primaryMapID { reason = "Only schedules on the verified primary map can be edited." }
        return ScheduleEntry(id:id,name:name,enabled:enabled,hour:timing?.hour,minute:timing?.minute,weekdays:timing?.weekdays,
            mode:mode,roomIDs:roomIDs,mapID:mapID,cron:cron,supportedEditReason:reason,originalJSON:original)
    }

    private static func editable(_ value: ScheduleEntry, primaryMapID: Int) throws -> [String: Any] {
        let raw = try object(value.originalJSON)
        let checked = try entry(id: value.id, raw: raw, primaryMapID: primaryMapID)
        guard checked.canEdit, checked.roomIDs == value.roomIDs, checked.mode == value.mode, checked.mapID == value.mapID else { throw invalid(checked.supportedEditReason ?? "Refresh the schedule before editing.") }
        return raw
    }
    private static func additionalBody(id: String, raw: [String: Any], device: RobotDevice) throws -> Data {
        try validateDevice(device); try validateKey(id)
        return try encode(["deviceId":device.id,"productId":device.productKey,"scheduled_cleaning_tasks":[id:raw]])
    }
    private static func modeFor(_ code: Int?) -> CleaningMode? { switch code { case 2:return .vacuum;case 3:return .mop;case 4:return .vacuumMop;case 5:return .vacuumThenMop;default:return nil } }
    private static func readbackDefaults(_ raw:[String:Any]) -> [String:Any] {
        // ScheduledCleaningTask.enable is a proto3 bool. A disabled schedule's
        // field may be omitted by the server serializer. No unknown field, enum,
        // message presence, or non-boolean value is normalized here.
        var value=raw
        if value["enable"] == nil { value["enable"]=false }
        return value
    }
    private static func epochMilliseconds(_ date:Date) throws -> Int64 {
        let seconds=date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < 4_102_444_800 else { throw invalid("The schedule creation time is invalid.") }
        return Int64((seconds*1000).rounded(.down))
    }
    private static func alias(_ raw: [String:Any], _ a:String, _ b:String) throws -> Any? {
        guard raw[a] == nil || raw[b] == nil else { throw invalid("A schedule contains conflicting field names.") }; return raw[a] ?? raw[b]
    }
    private static func enumNumber(_ value: Any?, names: [String:Int]) throws -> Int? {
        if let text = value as? String {
            if let result = names[text] { return result }
            if text.range(of: #"^[0-9]+$"#, options:.regularExpression) == nil { return nil }
        }
        return try number(value)
    }
    private static func number(_ value: Any?) throws -> Int? {
        guard let value else { return nil }
        if let string = value as? String, string.range(of:#"^(0|[1-9][0-9]{0,9})$"#,options:.regularExpression) != nil,
           let n=Int(string), n <= Int(UInt32.max) { return n }
        guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue.rounded(.towardZero) == n.doubleValue, n.doubleValue >= 0, n.doubleValue <= Double(UInt32.max) else { throw invalid("A schedule contains an invalid integer.") }
        return n.intValue
    }
    private static func bool(_ value: Any?) -> Bool? { guard let n=value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }; return n.boolValue }
    private static func successCode(_ value:Any?) -> Bool {
        guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }; return n.doubleValue == 0
    }
    private static func validateKey(_ key:String) throws {
        guard key.utf8.count <= 64, UUID(uuidString:key) != nil else { throw invalid("The schedule identifier is not recognized.") }
    }
    private static func validateDevice(_ device:RobotDevice) throws {
        guard device.canControl, device.id.range(of:#"^[A-Za-z0-9]{1,64}$"#,options:.regularExpression) != nil else { throw invalid("This schedule request does not match a supported robot.") }
    }
    private static func encode(_ value:[String:Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw invalid("The schedule cannot be safely preserved.") }
        let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]); guard data.count <= limit else { throw invalid("The schedule response is too large.") }; return data
    }
    private static func object(_ data:Data) throws -> [String:Any] {
        guard !data.isEmpty, data.count <= limit else { throw invalid("The schedule response is empty or too large.") }
        var depth=0, quoted=false, escaped=false
        for byte in data {
            if quoted { if escaped { escaped=false } else if byte == 92 { escaped=true } else if byte == 34 { quoted=false } }
            else if byte == 34 { quoted=true }
            else if byte == 123 || byte == 91 { depth += 1; guard depth <= 24 else { throw invalid("The schedule response is too deeply nested.") } }
            else if byte == 125 || byte == 93 { depth -= 1; guard depth >= 0 else { throw invalid("The schedule response is malformed.") } }
        }
        guard depth == 0, !quoted, let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw invalid("The schedule response is not an object.") }; return object
    }
    private static func invalid(_ message:String) -> ConnectorError { .invalid(message) }
}
