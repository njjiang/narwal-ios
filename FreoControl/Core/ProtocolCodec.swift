import Foundation
import zlib

/// Original bounded wire codec shared by the native app's read and control paths.
/// Protocol observations inform the field layout; an acknowledgement is not
/// evidence that the robot completed a physical action.
public enum NarwalCodec {
    static let frameLimit = 128 * 1024
    private static let mapLimit = 1024 * 1024
    private static let expandedLimit = 8 * 1024 * 1024
    static let maxID: UInt64 = 0x7fffffff

    struct Field {
        let tag: Int
        let wire: Int
        let integer: UInt64?
        let bytes: Data?
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }

        mutating func integer(maximum: UInt64 = UInt64.max, canonical: Bool = false) throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw invalid("Truncated protocol integer.") }
                let byte = bytes[offset]
                offset += 1
                let part = UInt64(byte & 0x7f)
                let shift = index * 7
                guard part <= (maximum >> shift) else { throw invalid("Protocol integer exceeds its limit.") }
                value |= part << shift
                guard value <= maximum else { throw invalid("Protocol integer exceeds its limit.") }
                if byte & 0x80 == 0 {
                    if canonical && index > 0 && part == 0 { throw invalid("Ambiguous pixel integer.") }
                    return value
                }
                if maximum == UInt64(UInt32.max) && index == 4 { break }
            }
            throw invalid("Protocol integer exceeds its limit.")
        }

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw invalid("Truncated protocol field.") }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }
    }

    private static func invalid(_ message: String) -> ConnectorError { .invalid(message) }

    static func fields(_ data: Data, limit: Int = frameLimit, countLimit: Int = 256) throws -> [Field] {
        guard data.count <= limit else { throw invalid("Protocol response exceeds its size limit.") }
        var reader = Reader(bytes: Array(data))
        var result: [Field] = []
        while reader.remaining > 0 {
            guard result.count < countLimit else { throw invalid("Too many protocol fields.") }
            let key = try reader.integer(maximum: UInt64(UInt32.max))
            let tag = Int(key >> 3), wire = Int(key & 7)
            guard tag > 0 else { throw invalid("Invalid protocol field number.") }
            switch wire {
            case 0:
                result.append(Field(tag: tag, wire: wire, integer: try reader.integer(), bytes: nil))
            case 1, 5:
                result.append(Field(tag: tag, wire: wire, integer: nil, bytes: try reader.take(wire == 1 ? 8 : 4)))
            case 2:
                let length = try reader.integer(maximum: UInt64(UInt32.max))
                result.append(Field(tag: tag, wire: wire, integer: nil, bytes: try reader.take(Int(length))))
            default:
                throw invalid("Unsupported protocol wire type.")
            }
        }
        return result
    }

    static func one(_ fields: [Field], _ tag: Int) throws -> Field? {
        let matches = fields.filter { $0.tag == tag }
        guard matches.count <= 1 else { throw invalid("Duplicate protocol singleton field.") }
        return matches.first
    }

    static func scalar(_ field: Field?, maximum: UInt64 = maxID, positive: Bool = false) throws -> Int? {
        guard let field else { return nil }
        guard field.wire == 0, let number = field.integer, number <= maximum, !positive || number > 0 else {
            throw invalid("Invalid protocol numeric field.")
        }
        return Int(number)
    }

    static func message(_ field: Field?, required: Bool = false) throws -> Data? {
        guard let field else {
            if required { throw invalid("Required protocol message is missing.") }
            return nil
        }
        guard field.wire == 2, let data = field.bytes else { throw invalid("Invalid protocol message field.") }
        return data
    }

    private static func validIdentifier(_ value: String) -> Bool {
        [32, 36].contains(value.utf8.count) && value.range(of: "^(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$", options: .regularExpression) != nil
    }

    static func unwrap(_ payload: Data, limit: Int = frameLimit) throws -> Data {
        guard payload.count <= limit else { throw invalid("Response exceeds its size limit.") }
        var reader = Reader(bytes: Array(payload))
        guard reader.remaining >= 2, reader.bytes[0] == 1 else { throw invalid("Unrecognized Narwal response framing.") }
        reader.offset = 1
        let declared = Int(try reader.integer(maximum: UInt64(UInt32.max)))
        guard declared <= reader.remaining else { throw invalid("Response length exceeds its frame.") }
        let body = try reader.take(reader.remaining)
        let prefix = Data(body.prefix(declared)), suffix = Data(body.dropFirst(declared))
        // The declared length may cover only a complete prefix. Validate both
        // boundaries before handling the separately framed account header.
        let prefixFields = try fields(prefix, limit: limit)
        _ = try fields(suffix, limit: limit)
        _ = try fields(body, limit: limit)
        if declared < body.count, try one(prefixFields, 1)?.wire == 2 {
            guard prefixFields.count == 2 else { throw invalid("Unrecognized response identity header.") }
            for tag in [1, 2] {
                guard let bytes = try message(one(prefixFields, tag)),
                      let text = String(data: bytes, encoding: .utf8), validIdentifier(text) else {
                    throw invalid("Unrecognized response identity header.")
                }
            }
            return suffix
        }
        return body
    }

    private static func response(_ data: Data, limit: Int = frameLimit) throws -> [Field] {
        let result = try fields(unwrap(data, limit: limit), limit: limit)
        _ = try one(result, 1)
        _ = try one(result, 2)
        return result
    }

    private static func successData(_ data: Data, limit: Int = frameLimit) throws -> Data {
        let result = try response(data, limit: limit)
        guard try scalar(one(result, 1)) == 1 else { throw invalid("Robot did not return a recognized success response.") }
        return try message(one(result, 2), required: true)!
    }

    private static func varint(_ number: UInt64) -> Data {
        var number = number
        var result = Data()
        repeat {
            let low = UInt8(number & 127)
            number >>= 7
            result.append(low | (number > 0 ? 128 : 0))
        } while number > 0
        return result
    }

    static func encodeNumber(_ tag: Int, _ value: UInt64) -> Data { varint(UInt64(tag * 8)) + varint(value) }
    static func encodeBytes(_ tag: Int, _ value: Data) -> Data { varint(UInt64(tag * 8 + 2)) + varint(UInt64(value.count)) + value }

    public static func identity(uuid: String) throws -> Data {
        guard validIdentifier(uuid) else { throw invalid("Invalid account identifier.") }
        let bytes = Data(uuid.utf8)
        let inner = encodeBytes(1, bytes) + encodeBytes(2, bytes)
        return Data([1]) + varint(UInt64(inner.count)) + inner
    }

    public static func correlation(id: String, timestamp: UInt64) throws -> Data {
        guard validIdentifier(id) else { throw invalid("Invalid request identifier.") }
        return encodeBytes(1, Data(id.utf8)) + encodeNumber(3, 0) + encodeNumber(4, timestamp)
    }

    public static func command(uuid: String, action: RobotAction, mode: CleaningMode, roomIDs: [Int], mapID: Int?, options: CleaningOptions = .standard) throws -> (topic: String, payload: Data) {
        let header = try identity(uuid: uuid)
        switch action {
        case .pause: return ("task/pause", header)
        case .resume: return ("task/resume", header)
        case .dock: return ("supply/recall", header)
        case .start: break
        }
        try options.validate()
        guard let mapID, mapID > 0, mapID <= Int(maxID) else { throw invalid("Starting requires the active map ID read from this robot.") }
        guard !roomIDs.isEmpty, roomIDs.count <= 100, Set(roomIDs).count == roomIDs.count,
              roomIDs.allSatisfy({ $0 > 0 && $0 <= Int(maxID) }) else {
            throw invalid("Starting requires 1–100 distinct room IDs read from this robot.")
        }
        let parameter: UInt64, task: UInt64, countTags: [Int]
        switch mode {
        case .vacuum: (parameter, task, countTags) = (2, 1, [5])
        case .mop: (parameter, task, countTags) = (3, 2, [6])
        case .vacuumMop: (parameter, task, countTags) = (4, 4, [7])
        case .vacuumThenMop: (parameter, task, countTags) = (5, 3, [5, 6])
        }
        // Preserve the original standard task byte-for-byte by default. These
        // options only affect the new task; they never adjust an active clean.
        var parameters = encodeNumber(1, parameter) + encodeNumber(2, UInt64(options.suction.rawValue)) + encodeNumber(3, 1) + encodeNumber(4, UInt64(options.humidity.rawValue))
        for tag in countTags { parameters += encodeNumber(tag, UInt64(options.passes)) }
        parameters += encodeNumber(8, UInt64(options.route.rawValue))
        var cleaning = encodeNumber(1, UInt64(mapID))
        for (index, id) in roomIDs.enumerated() {
            let zone = encodeNumber(1, 1) + encodeNumber(2, UInt64(id))
            let item = encodeBytes(1, zone) + encodeBytes(2, parameters) + encodeNumber(3, UInt64(index + 1))
            cleaning += encodeBytes(2, item)
        }
        cleaning += encodeBytes(3, Data()) + encodeNumber(5, task)
        // The cleaning request follows the declared identity frame, as observed
        // in the official app protocol. It is one native task, including seq.
        return ("clean/start_clean", header + encodeBytes(1, cleaning))
    }

    public static func status(_ data: Data) throws -> RobotStatus {
        let body = try fields(successData(data))
        let batteryField = try one(body, 2), work = try one(body, 3)
        var battery: Double?
        if batteryField?.wire == 5, let bytes = batteryField?.bytes {
            let array = Array(bytes)
            let bits = array.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
            let value = Double(Float(bitPattern: bits))
            if value.isFinite && value >= 0 && value <= 100 { battery = (value * 10).rounded() / 10 }
        }
        var workingCode: Int?, isPaused: Bool?
        if work?.wire == 2, let bytes = work?.bytes {
            let workFields = try fields(bytes)
            let code = try one(workFields, 1)
            if code?.wire == 0, let value = code?.integer, value <= maxID { workingCode = Int(value) }
            // Field 3.2 is an explicit pause overlay in both independent
            // protocol observations. The task enum itself is firmware-dependent.
            // Missing, mistyped and unfamiliar values remain unknown.
            let paused = try one(workFields, 2)
            if paused?.wire == 0, let value = paused?.integer, value <= 1 { isPaused = value == 1 }
        }
        let station = try one(body, 11)
        let stationCode = station?.wire == 0 ? station?.integer.flatMap(Int.init(exactly:)) : nil
        let suction = try one(body, 26)
        let suctionCode = suction?.wire == 0 ? suction?.integer.flatMap(Int.init(exactly:)) : nil
        return RobotStatus(battery: battery, workingCode: workingCode, isPaused: isPaused,
                           stationContactCode: stationCode, reportedSuctionCode: suctionCode)
    }

    // Room field 2 is the app's shared RoomType; field 8 numbers duplicate types.
    // Evidence: app switch/object-pool mapping, not room IDs or JSON key order.
    // https://github.com/sjmotew/NarwalIntegration/pull/48#issuecomment-5139063254
    private static let roomTypeNames = [
        "Room", "Master bedroom", "Secondary bedroom", "Living room", "Kitchen",
        "Bathroom", "Toilet", "Balcony", "Dining room", "Closet", "Corridor",
        "Study", "Kids' room", "Entertainment room", "Storage room", "Others"
    ]

    static func room(_ data: Data) throws -> RobotRoom {
        let entries = try fields(data, limit: 4096, countLimit: 64)
        guard let id = try scalar(one(entries, 1), positive: true) else { throw invalid("Room identifier is missing.") }
        let type = try scalar(one(entries, 2)), instance = try scalar(one(entries, 8))
        var name = "Room \(id)"
        if let type, type < roomTypeNames.count {
            name = roomTypeNames[type]
            if let instance, instance > 1 { name += " \(instance)" }
        }
        if let value = try message(one(entries, 3)) {
            guard value.count <= 256, let raw = String(data: value, encoding: .utf8) else { throw invalid("Invalid room name encoding.") }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.unicodeScalars.count <= 64, !text.unicodeScalars.contains(where: {
                $0.value <= 0x1f || (0x7f...0x9f).contains($0.value)
            }) else { throw invalid("Invalid room name.") }
            if !text.isEmpty { name = text }
        }
        return RobotRoom(id: id, name: name)
    }

    private static func roomMap(_ map: Data) throws -> RoomMap {
        let entries = try fields(map, limit: mapLimit, countLimit: 1024)
        let mapID = try scalar(one(entries, 1), positive: true)
        let revision = try scalar(one(entries, 33), maximum: UInt64(UInt32.max)).map(UInt32.init)
        let records = entries.filter { $0.tag == 12 }
        guard records.count <= 100 else { throw invalid("Room count exceeds its limit.") }
        var result: [RobotRoom] = [], ids = Set<Int>()
        for record in records {
            let parsed = try room(message(record, required: true)!)
            guard ids.insert(parsed.id).inserted else { throw invalid("Duplicate room identifier.") }
            result.append(parsed)
        }
        return RoomMap(mapID: mapID, rooms: result, mapRevision: revision)
    }

    public static func rooms(_ data: Data) throws -> RoomMap { try roomMap(successData(data, limit: mapLimit)) }

    private static func inflateGrid(_ data: Data) throws -> Data {
        guard data.count >= 2, data.count <= mapLimit else { throw invalid("Missing compressed floorplan.") }
        let header = Array(data.prefix(2))
        let gzip = header[0] == 0x1f && header[1] == 0x8b
        let standard = (header[0] & 15) == 8 && header[0] >> 4 <= 7 && (Int(header[0]) * 256 + Int(header[1])) % 31 == 0
        guard gzip || standard else { throw invalid("Unsupported floorplan compression.") }
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw invalid("Floorplan decompression could not initialize.")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input -> Data in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data(), chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let beforeInput = stream.total_in, beforeOutput = stream.total_out
                let status = chunk.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                guard produced <= expandedLimit - result.count else { throw invalid("Floorplan expansion exceeds its size limit.") }
                result.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.total_in == data.count else { throw invalid("Trailing compressed floorplan data.") }
                    return result
                }
                guard status == Z_OK, stream.total_in > beforeInput || stream.total_out > beforeOutput else {
                    throw invalid("Invalid compressed floorplan.")
                }
            }
        }
    }

    public static func floorplan(_ data: Data) throws -> Floorplan {
        let map = try successData(data, limit: mapLimit)
        return try decodeFloorplan(map)
    }

    /// Strict snapshot validation is intentionally separate from display:
    /// robots that omit revision fields can still display their floorplan.
    public static func mapSnapshot(_ data: Data, device: RobotDevice, capturedAt: Date = Date()) throws -> MapSnapshot {
        try decodeSnapshot(successData(data, limit: mapLimit), device: device, capturedAt: capturedAt)
    }

    private static func decodeSnapshot(_ map: Data, device: RobotDevice, capturedAt: Date) throws -> MapSnapshot {
        guard (1...32).contains(device.productKey.utf8.count), device.id.utf8.count == 32,
              device.productKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              device.id.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw invalid("A map snapshot requires a valid discovered robot identity.")
        }
        let entries = try fields(map, limit: mapLimit, countLimit: 1024)
        // StaticMapPayload: field 2 mapVersion, field 33 editVersion.
        // https://github.com/cvette/narwal-ha/blob/ef6c0729c405a37070b24b4bdb1ae93739baa059/custom_components/narwal_local/protocol/map.py
        // Explicit zero counters are preserved. Absence is never filled with 0.
        guard let mapVersion = try scalar(one(entries, 2), maximum: UInt64(UInt32.max)),
              let editVersion = try scalar(one(entries, 33), maximum: UInt64(UInt32.max)) else {
            throw invalid("Map snapshot unavailable: the robot did not return both map revision fields.")
        }
        let floorplan = try decodeFloorplan(map)
        return MapSnapshot(productKey: device.productKey, deviceID: device.id, mapID: floorplan.mapID,
                           mapVersion: UInt32(mapVersion), editVersion: UInt32(editVersion),
                           capturedAt: capturedAt, floorplan: floorplan, staticMapPayload: map)
    }

    // Narwal Android 2.10.90 generated GetEditableMap/MapOperation schemas and
    // RoomManagerControllerBase save flow; offline evidence is retained in work.
    public static func editableMapRequest(uuid: String, mapID: Int) throws -> Data {
        guard mapID > 0, mapID <= Int(maxID) else { throw invalid("A valid map ID is required.") }
        // Compressed grid, without optional carpet/floorplan overlays. These
        // flags change the returned representation, not the saved map.
        return try identity(uuid: uuid) + encodeNumber(1, UInt64(mapID)) + encodeNumber(2, 0) + encodeNumber(3, 0) + encodeNumber(4, 0)
    }

    public static func editableMapSnapshot(_ data: Data, device: RobotDevice, mapID: Int, capturedAt: Date = Date()) throws -> MapSnapshot {
        let root = try response(data, limit: mapLimit)
        guard try scalar(one(root, 1)) == 1 else { throw invalid("Narwal did not return an editable map.") }
        guard let revision = try scalar(one(root, 3), maximum: UInt64(UInt32.max)) else {
            throw invalid("The editable map omitted its edit revision.")
        }
        if let error = try scalar(one(root, 5), maximum: UInt64(UInt32.max)), error != 0 {
            throw invalid("Narwal reported an editable-map error (\(error)).")
        }
        var snapshot = try decodeSnapshot(message(one(root, 2), required: true)!, device: device, capturedAt: capturedAt)
        guard snapshot.mapID == mapID, snapshot.editVersion == UInt32(revision) else {
            throw invalid("The editable map identity or revision does not match its response.")
        }
        if let config = try message(one(root, 4)) {
            let entries = try fields(config, limit: 4096)
            if let maximum = try scalar(one(entries, 1), maximum: 255, positive: true) {
                snapshot.maximumRoomCount = maximum
            }
        }
        return snapshot
    }

    public static func roomOperationRequest(uuid: String, baseline: MapSnapshot, operations: [RoomMapOperation]) throws -> Data {
        guard baseline.mapID > 0, baseline.mapID <= Int(maxID) else { throw invalid("A valid map snapshot is required.") }
        guard !operations.isEmpty, operations.count <= 64 else { throw invalid("A room edit requires 1–64 reviewed operations.") }
        var body = encodeNumber(1, UInt64(baseline.mapID)) + encodeNumber(2, UInt64(baseline.mapVersion)) + encodeNumber(3, UInt64(baseline.editVersion))
        func roomID(_ value: Int) throws -> UInt64 {
            guard (1...255).contains(value) else { throw invalid("Room edits require valid eight-bit room identifiers.") }
            return UInt64(value)
        }
        func point(_ value: MapEditPoint) throws -> Data {
            guard value.x.isFinite, value.y.isFinite, abs(value.x) <= 1_000_000, abs(value.y) <= 1_000_000 else { throw invalid("The room cut contains an invalid coordinate.") }
            func float(_ tag: UInt8, _ value: Float) -> Data {
                let bits = value.bitPattern
                return Data([tag << 3 | 5, UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24)])
            }
            return float(1, value.x) + float(2, value.y)
        }
        for operation in operations {
            let encoded: Data
            switch operation {
            case .split(let start, let end, let left, let right):
                guard start != end, left != right else { throw invalid("A room split needs a nonempty cut and distinct side IDs.") }
                let split = try encodeBytes(1, point(start)) + encodeBytes(2, point(end)) + encodeNumber(3, roomID(left)) + encodeNumber(4, roomID(right))
                encoded = encodeBytes(1, split)
            case .merge(let first, let second, let result):
                guard first != second else { throw invalid("A room merge requires two distinct rooms.") }
                encoded = try encodeBytes(2, encodeNumber(1, roomID(first)) + encodeNumber(2, roomID(second)) + encodeNumber(3, roomID(result)))
            case .rename(let id, let name):
                _ = try roomID(id)
                encoded = try encodeBytes(3, encodeBytes(1, renamedRoomInfo(snapshot: baseline, roomID: id, name: name)))
            }
            body += encodeBytes(4, encoded)
        }
        body += encodeNumber(5, 0) + encodeNumber(6, 0) + encodeNumber(7, 0)
        guard body.count <= frameLimit - 128 else { throw invalid("The room edit exceeds its size limit.") }
        return try identity(uuid: uuid) + body
    }

    public static func validateRoomName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256, name.unicodeScalars.count <= 64,
              !name.unicodeScalars.contains(where: { $0.value <= 31 || (127...159).contains($0.value) }) else { throw invalid("Use a room name of 1–64 characters without control characters.") }
    }

    /// Strict post-edit preservation check. A transaction may additionally
    /// supply its immediately preceding snapshot and exact operation so room
    /// adjacency changes can be verified rather than treated as opaque data.
    /// The caller independently verifies room records/raster against its plan.
    /// All other metadata, including unknown fields, remains protected.
    public static func validateRoomEditReadback(baseline: MapSnapshot, current: MapSnapshot,
                                                mutableRoomIDs: Set<Int> = [],
                                                precedingSnapshot: MapSnapshot? = nil,
                                                operations: [RoomMapOperation] = [], allowsGridRounding: Bool = false,
                                                roomIDMapping: [Int: Int] = [:],
                                                precedingRoomIDMapping: [Int: Int] = [:]) throws {
        guard baseline.productKey == current.productKey, baseline.deviceID == current.deviceID, baseline.mapID == current.mapID else {
            throw invalid("The edited map belongs to a different robot or map. Further edits stopped.")
        }
        let hasVerifiedDoorChanges: Bool
        if let precedingSnapshot {
            guard !operations.isEmpty,
                  precedingSnapshot.productKey == current.productKey,
                  precedingSnapshot.deviceID == current.deviceID,
                  precedingSnapshot.mapID == current.mapID else {
                throw invalid("Room boundary verification requires the preceding map and its operation.")
            }
            try RoomDoorReadback.validate(baseline: precedingSnapshot, current: current, operations: operations,
                                          allowsGridRounding: allowsGridRounding, roomIDMapping: precedingRoomIDMapping)
            hasVerifiedDoorChanges = true
        } else {
            guard operations.isEmpty else { throw invalid("Read the preceding map before verifying room boundaries.") }
            hasVerifiedDoorChanges = false
        }
        func preservedFields(_ data: Data) throws -> [Int: [Data]] {
            _ = try fields(data, limit: mapLimit, countLimit: 1024)
            var reader = Reader(bytes: Array(data)), result: [Int: [Data]] = [:]
            while reader.remaining > 0 {
                let start = reader.offset, key = try reader.integer(maximum: UInt64(UInt32.max)), tag = Int(key >> 3)
                switch key & 7 {
                case 0: _ = try reader.integer()
                case 1: _ = try reader.take(8)
                case 2: _ = try reader.take(Int(reader.integer(maximum: UInt64(UInt32.max))))
                case 5: _ = try reader.take(4)
                default: throw invalid("Unsupported map metadata field.")
                }
                if ![2, 12, 17, 33].contains(tag) && !(tag == 11 && hasVerifiedDoorChanges) {
                    result[tag, default: []].append(Data(reader.bytes[start..<reader.offset]))
                }
            }
            return result
        }
        guard try preservedFields(baseline.staticMapPayload) == preservedFields(current.staticMapPayload) else {
            throw invalid("The robot changed additional map metadata. Further edits stopped; inspect the current map before continuing.")
        }
        func roomRecords(_ data: Data) throws -> [Int: Data] {
            var records: [Int: Data] = [:]
            for field in try fields(data, limit: mapLimit, countLimit: 1024) where field.tag == 12 {
                let raw = try message(field, required: true)!
                let room = try fields(raw, limit: 4096, countLimit: 64)
                guard let id = try scalar(one(room, 1), positive: true), records[id] == nil else {
                    throw invalid("The map has invalid or duplicate room metadata.")
                }
                records[id] = raw
            }
            return records
        }
        let originalRooms = try roomRecords(baseline.staticMapPayload)
        let currentRooms = try roomRecords(current.staticMapPayload)
        guard mutableRoomIDs.isSubset(of: Set(originalRooms.keys)) else {
            throw invalid("The editable rooms are not present in the reviewed map.")
        }
        for (id, record) in originalRooms where !mutableRoomIDs.contains(id) {
            let returnedID = roomIDMapping[id] ?? id
            let expectedRecord: Data
            if returnedID != id {
                var reader = Reader(bytes: Array(record))
                var retained = Data()
                while reader.remaining > 0 {
                    let start = reader.offset
                    let key = try reader.integer(maximum: UInt64(UInt32.max))
                    switch key & 7 {
                    case 0: _ = try reader.integer()
                    case 1: _ = try reader.take(8)
                    case 2: _ = try reader.take(Int(reader.integer(maximum: UInt64(UInt32.max))))
                    case 5: _ = try reader.take(4)
                    default: throw invalid("Unsupported room metadata field.")
                    }
                    if key >> 3 != 1 { retained += Data(reader.bytes[start..<reader.offset]) }
                }
                expectedRecord = encodeNumber(1, UInt64(returnedID)) + retained
            } else { expectedRecord = record }
            guard currentRooms[returnedID] == expectedRecord else {
                throw invalid("An unselected room’s metadata changed. Further edits stopped; inspect the current map before continuing.")
            }
        }
    }

    /// A rename may change only the requested name fields and map revisions.
    /// The actual raster (including room IDs and unreachable cells), room list,
    /// adjacency, and every other known or opaque metadata field stay intact.
    public static func validateRoomRenameReadback(baseline: MapSnapshot, current: MapSnapshot,
                                                   names: [Int: String]) throws {
        guard !names.isEmpty, names.count <= 64 else {
            throw invalid("Verify the exact requested room names before saving.")
        }
        for name in names.values { try validateRoomName(name) }
        let before = baseline.floorplan, after = current.floorplan
        guard before.mapID == after.mapID, before.width == after.width, before.height == after.height,
              before.resolution == after.resolution, before.pixels == after.pixels,
              Set(before.rooms.map(\.id)) == Set(after.rooms.map(\.id)) else {
            throw invalid("Renaming changed the saved room shapes. Further edits stopped.")
        }
        try validateRoomEditReadback(baseline: baseline, current: current, mutableRoomIDs: Set(names.keys))
        func records(_ snapshot: MapSnapshot) throws -> [Int: Data] {
            var result: [Int: Data] = [:]
            for field in try fields(snapshot.staticMapPayload, limit: mapLimit, countLimit: 1024) where field.tag == 12 {
                let raw = try message(field, required: true)!
                let parts = try fields(raw, limit: 4096, countLimit: 64)
                guard let id = try scalar(one(parts, 1), positive: true), result[id] == nil else {
                    throw invalid("The saved map has invalid room metadata.")
                }
                result[id] = raw
            }
            guard Set(result.keys) == Set(snapshot.floorplan.rooms.map(\.id)) else {
                throw invalid("The saved room list and room metadata disagree.")
            }
            return result
        }
        // Ignore ordering between different protobuf fields, while preserving
        // every field's exact bytes and the order of repeated values.
        func encodedFields(_ data: Data) throws -> [Int: [Data]] {
            _ = try fields(data, limit: 4096, countLimit: 64)
            var reader = Reader(bytes: Array(data)), result: [Int: [Data]] = [:]
            while reader.remaining > 0 {
                let start = reader.offset, key = try reader.integer(maximum: UInt64(UInt32.max))
                switch key & 7 {
                case 0: _ = try reader.integer()
                case 1: _ = try reader.take(8)
                case 2: _ = try reader.take(Int(reader.integer(maximum: UInt64(UInt32.max))))
                case 5: _ = try reader.take(4)
                default: throw invalid("Unsupported room metadata field.")
                }
                result[Int(key >> 3), default: []].append(Data(reader.bytes[start..<reader.offset]))
            }
            return result
        }
        let original = try records(baseline), saved = try records(current)
        guard original.keys.sorted() == saved.keys.sorted(), Set(names.keys).isSubset(of: Set(original.keys)) else {
            throw invalid("Renaming changed the saved room identifiers.")
        }
        for (id, oldRecord) in original {
            let expected = try names[id].map { try renamedRoomInfo(snapshot: baseline, roomID: id, name: $0) } ?? oldRecord
            guard let actual = saved[id], try encodedFields(expected) == encodedFields(actual),
                  after.rooms.first(where: { $0.id == id })?.name == (names[id] ?? before.rooms.first(where: { $0.id == id })?.name) else {
                throw invalid("Renaming changed other room metadata or did not save the requested names.")
            }
        }
    }

    private static func renamedRoomInfo(snapshot: MapSnapshot, roomID: Int, name: String) throws -> Data {
        try validateRoomName(name)
        let map = try fields(snapshot.staticMapPayload, limit: mapLimit, countLimit: 1024)
        var matching: Data?
        for record in map where record.tag == 12 {
            let raw = try message(record, required: true)!
            let parts = try fields(raw, limit: 4096, countLimit: 64)
            if try scalar(one(parts, 1)) == roomID {
                guard matching == nil else { throw invalid("The map has duplicate room metadata.") }
                _ = try message(one(parts, 3))
                matching = raw
            }
        }
        guard let raw = matching else { throw invalid("Read the new room's saved metadata before naming it.") }
        // Preserve every non-name field byte for byte, including unknown fields.
        var reader = Reader(bytes: Array(raw)), result = Data()
        while reader.remaining > 0 {
            let start = reader.offset, key = try reader.integer(maximum: UInt64(UInt32.max))
            switch key & 7 {
            case 0: _ = try reader.integer()
            case 1: _ = try reader.take(8)
            case 2: _ = try reader.take(Int(reader.integer(maximum: UInt64(UInt32.max))))
            case 5: _ = try reader.take(4)
            default: throw invalid("Unsupported room metadata field.")
            }
            if key >> 3 != 3 { result += Data(reader.bytes[start..<reader.offset]) }
        }
        return result + encodeBytes(3, Data(name.utf8))
    }

    public static func mapEditAcknowledgement(_ data: Data) throws -> MapEditAcknowledgement {
        let root = try response(data, limit: mapLimit)
        guard let code = try scalar(one(root, 1), maximum: UInt64(UInt32.max)) else { throw invalid("The map edit reply omitted its result.") }
        _ = try message(one(root, 2))
        let revision = try scalar(one(root, 3), maximum: UInt64(UInt32.max))
        let error = try scalar(one(root, 4), maximum: UInt64(UInt32.max))
        let unified = try scalar(one(root, 5), maximum: UInt64(UInt32.max))
        guard code != 1 || revision != nil else { throw invalid("The map edit reply omitted its revision.") }
        return MapEditAcknowledgement(resultCode: code, errorCode: error, unifiedErrorCode: unified, editVersion: revision.map(UInt32.init))
    }

    static func decodeFloorplan(_ map: Data) throws -> Floorplan {
        let saved = try roomMap(map)
        guard let mapID = saved.mapID else { throw invalid("Floorplan has no active map ID.") }
        let entries = try fields(map, limit: mapLimit, countLimit: 1024)
        guard let width = try scalar(one(entries, 4), maximum: 4096, positive: true),
              let height = try scalar(one(entries, 5), maximum: 4096, positive: true), width * height <= 1_000_000 else {
            throw invalid("Floorplan dimensions are missing or exceed their limits.")
        }
        let resolution = try scalar(one(entries, 3), maximum: 1_000_000, positive: true)
        let compressed = try message(one(entries, 17), required: true)!
        var reader = try Reader(bytes: Array(inflateGrid(compressed)))
        guard try reader.integer(maximum: UInt64(UInt32.max), canonical: true) == 10 else { throw invalid("Unknown floorplan pixel wrapper.") }
        let length = try reader.integer(maximum: UInt64(UInt32.max), canonical: true)
        guard length == UInt64(reader.remaining) else { throw invalid("Floorplan wrapper length does not match.") }
        var pixels = [UInt32]()
        pixels.reserveCapacity(width * height)
        for _ in 0..<(width * height) {
            pixels.append(UInt32(try reader.integer(maximum: UInt64(UInt32.max), canonical: true)))
        }
        guard reader.remaining == 0 else { throw invalid("Floorplan pixel count does not match its dimensions.") }
        guard pixels.contains(where: { $0 != 0 }) else { throw invalid("Robot returned a blank floorplan.") }
        // Source rows are Y-up. Views flip row height-1-y; this is not a
        // world-coordinate transform or a writable polygon representation.
        return Floorplan(mapID: mapID, width: width, height: height, resolution: resolution, rooms: saved.rooms, pixels: pixels, mapRevision: saved.mapRevision)
    }

    public static func plan(_ data: Data) throws -> CleaningTaskSnapshot {
        let root = try response(data)
        guard let code = try scalar(one(root, 1), maximum: 65535) else { throw invalid("Missing cleaning-task result code.") }
        guard let body = try message(one(root, 2)) else {
            return CleaningTaskSnapshot(resultCode: code, mapID: nil, taskType: nil, optionFields: [:], samples: [])
        }
        let task = try fields(body)
        let mapID = try scalar(one(task, 1)), taskType = try scalar(one(task, 5))
        var options: [Int: UInt64] = [:]
        if let option = try one(task, 3) {
            if option.wire == 2, let bytes = option.bytes {
                let entries = try fields(bytes, limit: 4096)
                for field in entries where field.wire == 0 {
                    guard options.count < 64 else { throw invalid("Too many cleaning-task options.") }
                    options[field.tag] = UInt64(try scalar(one(entries, field.tag))!)
                }
            } else if option.wire == 0 {
                _ = try scalar(option) // A legacy scalar is not a nested flag.
            }
        }
        let items = task.filter { $0.tag == 2 }
        guard items.count <= 100 else { throw invalid("Cleaning-task item count exceeds its limit.") }
        var samples: [CleaningTaskSample] = []
        for item in items {
            let record = try fields(message(item, required: true)!)
            let zone = try fields(message(one(record, 1)) ?? Data())
            let type = try scalar(one(zone, 1)), id = try scalar(one(zone, 2))
            let parameters = try fields(message(one(record, 2)) ?? Data())
            var values: [Int: UInt64] = [:]
            // Official CleanParam field11 is sweepIntensityLevel. It is a
            // separate reported value from fanLevel2, not a fallback for it.
            for tag in 1...11 {
                if let number = try scalar(one(parameters, tag)) { values[tag] = UInt64(number) }
            }
            samples.append(CleaningTaskSample(roomID: type == 1 ? id : nil, parameters: values))
        }
        return CleaningTaskSnapshot(resultCode: code, mapID: mapID, taskType: taskType, optionFields: options, samples: samples)
    }

    /// /common/get_feature_list returns direct GetFeatureList.Response fields,
    /// unlike the ServiceResult/data envelope used by status and current task.
    /// A missing feature remains unreported; it is not proof of lack of support.
    public static func sweepIntensitySupport(_ data: Data) throws -> Bool? {
        let features = try fields(unwrap(data))
        // These are boolean feature fields in the official schema. Validate
        // them so a generic result/data error cannot masquerade as this reply.
        for tag in [1, 2] { _ = try scalar(one(features, tag), maximum: 1) }
        guard let value = try scalar(one(features, 113), maximum: 1) else { return nil }
        return value == 1
    }

    public static func acknowledgement(_ data: Data) throws -> CommandAcknowledgement {
        let entries = try response(data)
        guard let code = try scalar(one(entries, 1)) else { throw invalid("Unrecognized command acknowledgement.") }
        _ = try message(one(entries, 2))
        return CommandAcknowledgement(accepted: code == 1, resultCode: code)
    }
}
