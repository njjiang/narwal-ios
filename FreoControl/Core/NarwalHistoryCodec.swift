import Foundation
import CoreFoundation
import CryptoKit

/// A server-saved cleaning record. Its identifier is a decimal string because
/// real record IDs exceed 2^53; a Double/JavaScript Number would corrupt them.
public struct CloudCleaningRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let productKey: String
    public let deviceID: String
    public let startedAt: Date
    public let endedAt: Date?
    /// Reported active seconds, not necessarily end_time minus start_time.
    public let durationSeconds: Int?
    public let statusCode: Int?
    public let modeName: String?
    public let roomNames: [String]
    public let mapID: Int?
    public func matches(device: RobotDevice) -> Bool { productKey == device.productKey && deviceID == device.id }
    public init(id: String, productKey: String, deviceID: String, startedAt: Date, endedAt: Date? = nil,
                durationSeconds: Int? = nil, statusCode: Int? = nil, modeName: String? = nil,
                roomNames: [String] = [], mapID: Int? = nil) {
        self.id = id; self.productKey = productKey; self.deviceID = deviceID; self.startedAt = startedAt
        self.endedAt = endedAt; self.durationSeconds = durationSeconds; self.statusCode = statusCode
        self.modeName = modeName; self.roomNames = roomNames; self.mapID = mapID
    }
}

/// Original read-only decoder for the official app's saved cleaning endpoints.
/// Unknown URLs, account fields, and path-state guesses are never retained.
public enum NarwalHistoryCodec {
    private static let responseLimit = 8 * 1024 * 1024

    public static func records(_ data: Data, device: RobotDevice) throws -> [CloudCleaningRecord] {
        guard let list = try envelope(data) as? [[String: Any]], list.count <= 100 else {
            throw invalid("The saved cleaning list is not recognized.")
        }
        var ids = Set<String>(), records: [CloudCleaningRecord] = []
        for raw in list {
            try scope(raw, device: device, required: true)
            let id = try recordID(raw["record_id"])
            guard ids.insert(id).inserted else { throw invalid("The saved cleaning list contains duplicate records.") }
            let started = try date(raw["start_time"], required: true)!
            let ended = try date(raw["end_time"])
            guard ended.map({ $0 >= started }) ?? true else { throw invalid("Saved cleaning dates are out of order.") }
            let rooms = try roomCatalog(raw["room_infos"])
            var selectedNames: [String] = [], modeName: String?
            if let value = raw["clean_task"], !(value is NSNull) {
                guard let task = value as? [String: Any] else { throw invalid("Saved cleaning settings are not recognized.") }
                if let value = task["items"], !(value is NSNull) {
                    guard let items = value as? [[String: Any]], items.count <= 100 else { throw invalid("Too many saved room settings.") }
                    var modes = Set<Int>(), selected = Set<Int>(), completeModes = true
                    for item in items {
                        if let param = item["param"] as? [String: Any], let mode = try integer(param["mode"], maximum: Int32.max) { modes.insert(Int(mode)) }
                        else { completeModes = false }
                        if let zone = item["zone"] as? [String: Any], try integer(zone["zone_type"], maximum: 255) == 1,
                           let id = try integer(zone["zone_id"], maximum: 255), id > 0 { selected.insert(Int(id)) }
                    }
                    if selected.isSubset(of: Set(rooms.map(\.id))) { selectedNames = rooms.filter { selected.contains($0.id) }.map(\.name) }
                    if completeModes, modes.count == 1 { modeName = [2: "Vacuum", 3: "Mop", 4: "Vacuum & mop", 5: "Vacuum, then mop"][modes.first!] }
                    else if completeModes, modes.count > 1 { modeName = "Mixed room settings" }
                }
            }
            let duration = try integer(raw["duration"], maximum: 31 * 86_400).map(Int.init)
            let status = try integer(raw["record_status"], maximum: Int32.max).map(Int.init)
            let mapID = try integer(raw["map_id"], maximum: Int32.max).flatMap { $0 > 0 ? Int($0) : nil }
            records.append(CloudCleaningRecord(id: id, productKey: device.productKey, deviceID: device.id,
                startedAt: started, endedAt: ended, durationSeconds: duration, statusCode: status,
                modeName: modeName, roomNames: selectedNames, mapID: mapID))
        }
        return records.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
    }

    public static func detail(_ data: Data, record: CloudCleaningRecord, device: RobotDevice) throws -> CleaningRun {
        guard record.matches(device: device), let raw = try envelope(data) as? [String: Any] else {
            throw invalid("The saved route does not match the selected robot.")
        }
        try scope(raw, device: device, required: false)
        guard try recordID(raw["record_id"]) == record.id else { throw invalid("Narwal returned a different saved cleaning record.") }
        let started = try date(raw["start_time"], required: true)!
        guard started == record.startedAt else { throw invalid("The saved cleaning date changed. Refresh the history list.") }
        let ended = try date(raw["end_time"]) ?? record.endedAt ?? started
        guard ended >= started else { throw invalid("Saved cleaning dates are out of order.") }
        guard let mapID = try integer(raw["map_id"], maximum: Int32.max), mapID > 0,
              record.mapID.map({ Int(mapID) == $0 }) ?? true,
              let width = try integer(raw["width"], maximum: 4096), width > 0,
              let height = try integer(raw["height"], maximum: 4096), height > 0,
              width <= 1_000_000 / height,
              let border = raw["border"] as? [String: Any] else { throw invalid("The saved floorplan geometry is invalid.") }
        guard try integer(raw["map_data_format"], maximum: 255) == 3 else {
            throw invalid("This saved floorplan uses an unsupported data format.")
        }
        let version = try integer(raw["map_version"], maximum: UInt32.max).map(UInt32.init)
        let rooms = try roomCatalog(raw["room_infos"])
        var map = NarwalCodec.encodeNumber(1, UInt64(mapID)) + NarwalCodec.encodeNumber(4, UInt64(width)) + NarwalCodec.encodeNumber(5, UInt64(height))
        if let version { map += NarwalCodec.encodeNumber(2, UInt64(version)) }
        if let resolution = try integer(raw["resolution"], maximum: 1_000_000), resolution > 0 { map += NarwalCodec.encodeNumber(3, UInt64(resolution)) }
        var boundary = Data()
        for (name, tag) in [("bottom", 1), ("top", 2), ("left", 3), ("right", 4)] {
            let value = try signed(border[name]) ?? 0
            boundary += NarwalCodec.encodeNumber(tag, UInt64(bitPattern: Int64(value)))
        }
        map += NarwalCodec.encodeBytes(6, boundary)
        for room in rooms {
            map += NarwalCodec.encodeBytes(12, NarwalCodec.encodeNumber(1, UInt64(room.id)) + NarwalCodec.encodeBytes(3, Data(room.name.utf8)))
        }
        map += NarwalCodec.encodeBytes(17, try base64(raw["map_data"], required: true)!)
        if let rotation = try signed(raw["rotate_angle"]) { map += NarwalCodec.encodeNumber(25, UInt64(bitPattern: Int64(rotation))) }
        let format = try integer(raw["robot_trajectory_format"], maximum: UInt32.max) ?? 0
        map += NarwalCodec.encodeNumber(15, UInt64(format))
        if let bytes = try base64(raw["robot_trajectory"]) { map += NarwalCodec.encodeBytes(14, bytes) }
        if let value = raw["trajectory_infos"], !(value is NSNull) {
            guard let infos = value as? [[String: Any]], infos.count <= 900 else { throw invalid("The saved route has too many state changes.") }
            for info in infos {
                var encoded = Data()
                // Exact official RobotTrajectoryInfo descriptor. These are
                // explicit states; trajectory_start_indices is NOT this field.
                for (name, tag) in [("trajectory_type", 1), ("index", 2), ("group_id", 3), ("clean_count", 4), ("direction", 5)] {
                    if let value = try integer(info[name], maximum: UInt32.max) { encoded += NarwalCodec.encodeNumber(tag, UInt64(value)) }
                }
                map += NarwalCodec.encodeBytes(31, encoded)
            }
        }
        if let value = raw["trajectory_arcs"], !(value is NSNull) {
            guard let arcs = value as? [Any], arcs.isEmpty else { throw invalid("This saved route contains unsupported curves.") }
        }
        // Never read map_path, media URLs, user_uuid, account IDs, debug_data,
        // or archived original-route fields. No download is hidden in decoding.
        let floorplan = try NarwalCodec.decodeFloorplan(map)
        let route = try NarwalCodec.archivedTrajectory(mapPayload: map, floorplan: floorplan,
            device: device, capturedAt: ended, mapVersion: version)
        if let reason = route.unavailableReason { throw invalid(reason) }
        guard route.points.count >= 2 else { throw invalid("Narwal did not save a usable path for this cleaning.") }
        return CleaningRun(id: stableID(productKey: device.productKey, deviceID: device.id, recordID: record.id),
            startedAt: started, updatedAt: ended, floorplan: floorplan, trajectory: route,
            modeName: record.modeName, roomNames: record.roomNames,
            partialReason: CleaningHistoryStore.cloudSavedReason, cloudRecordID: record.id, importedAt: Date())
    }

    /// Namespace-separated hash, not Swift's randomized Hasher. No room names
    /// or account identifiers enter the stable archive filename.
    static func stableID(productKey: String, deviceID: String, recordID: String) -> UUID {
        let components = ["Freo saved route v1", productKey, deviceID, recordID]
        let source = components.map { "\($0.utf8.count):\($0)" }.joined()
        var bytes = Array(SHA256.hash(data: Data(source.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func envelope(_ data: Data) throws -> Any {
        guard data.count <= responseLimit,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              try integer(object["code"], maximum: Int32.max) == 0,
              let result = object["result"], !(result is NSNull) else {
            throw invalid("Narwal did not return saved cleaning history.")
        }
        if let success = object["success"] as? Bool, !success { throw invalid("Narwal did not return saved cleaning history.") }
        return result
    }
    private static func scope(_ raw: [String: Any], device: RobotDevice, required: Bool) throws {
        for (key, expected) in [("product_id", device.productKey), ("device_id", device.id)] {
            if let value = raw[key], !(value is NSNull) {
                guard let text = value as? String, text == expected else { throw invalid("Saved cleaning history belongs to a different robot.") }
            } else if required { throw invalid("Saved cleaning history omitted its robot identity.") }
        }
    }
    private static func recordID(_ value: Any?) throws -> String {
        guard let value = try integer(value, maximum: Int64.max), value > 0 else { throw invalid("The saved cleaning identifier is invalid.") }
        return String(value)
    }
    /// NSNumber's decimal integer representation preserves Int64 JSON values.
    /// Reject booleans, fractional/scientific strings, and floating JSON numbers.
    private static func integer(_ value: Any?, maximum: some BinaryInteger) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        let text: String
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), !["f", "d"].contains(String(cString: number.objCType)) else {
                throw invalid("Saved cleaning history contains an invalid integer.")
            }
            text = number.stringValue
        } else if let string = value as? String { text = string }
        else { throw invalid("Saved cleaning history contains an invalid integer.") }
        guard !text.isEmpty, text.utf8.count <= 19, text.utf8.allSatisfy({ (48...57).contains($0) }),
              text == "0" || text.first != "0", let result = Int64(text), result >= 0,
              UInt64(result) <= UInt64(maximum) else { throw invalid("Saved cleaning history contains an invalid integer.") }
        return result
    }
    private static func date(_ value: Any?, required: Bool = false) throws -> Date? {
        guard let seconds = try integer(value, maximum: 4_102_444_800) else {
            if required { throw invalid("The saved cleaning date is missing.") }; return nil
        }
        // Some ongoing records use zero for an unavailable end time.
        if seconds == 0, !required { return nil }
        guard seconds >= 946_684_800 else { throw invalid("The saved cleaning date is invalid.") }
        let result = Date(timeIntervalSince1970: Double(seconds))
        guard result <= Date().addingTimeInterval(300) else { throw invalid("The saved cleaning date is in the future.") }
        return result
    }
    private static func signed(_ value: Any?) throws -> Int32? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let result = Int32(number.stringValue) else { throw invalid("The saved map coordinate is invalid.") }
        return result
    }
    private static func base64(_ value: Any?, required: Bool = false) throws -> Data? {
        guard let value, !(value is NSNull) else {
            if required { throw invalid("The saved floorplan data is missing.") }; return nil
        }
        guard let text = value as? String, text.utf8.count <= 1_400_000,
              let bytes = Data(base64Encoded: text), bytes.count <= 1024 * 1024 else {
            throw invalid("Saved route data is invalid or too large.")
        }
        return bytes
    }
    private static func roomCatalog(_ value: Any?) throws -> [RobotRoom] {
        guard let value, !(value is NSNull) else { return [] }
        guard let raw = value as? [[String: Any]], raw.count <= 100 else { throw invalid("The saved room list is invalid.") }
        var result: [RobotRoom] = [], ids = Set<Int>()
        for item in raw {
            guard let id = try integer(item["room_id"], maximum: 255), id > 0, ids.insert(Int(id)).inserted else {
                throw invalid("The saved room identity is invalid.")
            }
            var room = NarwalCodec.encodeNumber(1, UInt64(id))
            if let type = try integer(item["type"], maximum: Int32.max) { room += NarwalCodec.encodeNumber(2, UInt64(type)) }
            if let name = item["custom_name"], !(name is NSNull) {
                guard let name = name as? String, name.utf8.count <= 256 else { throw invalid("The saved room name is invalid.") }
                room += NarwalCodec.encodeBytes(3, Data(name.utf8))
            }
            result.append(try NarwalCodec.room(room))
        }
        return result
    }
    private static func invalid(_ message: String) -> ConnectorError { .invalid(message) }
}
