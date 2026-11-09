import Foundation

/// An in-memory Siri room identity. Names are presentation only and never enter
/// the stable identifier. This type does not store credentials or persist data.
public struct SiriRoomReference: Identifiable, Equatable, Sendable, Codable {
    public let productKey: String
    public let deviceID: String
    public let mapID: Int
    public let roomID: Int
    public let name: String
    public let mapRevision: UInt32?

    /// The caller may construct this from already-validated discovery results.
    /// `validate` still checks every field before returning command room IDs.
    public init(productKey: String, deviceID: String, mapID: Int, roomID: Int, name: String, mapRevision: UInt32? = nil) {
        self.productKey = productKey
        self.deviceID = deviceID
        self.mapID = mapID
        self.roomID = roomID
        self.name = name
        self.mapRevision = mapRevision
    }

    /// Versioned, canonical components prevent delimiter collisions even when
    /// a caller constructs an invalid reference before validating it.
    public var id: String {
        var parts = ["freo-room", mapRevision == nil ? "v1" : "v2", Self.encode(productKey), Self.encode(deviceID), String(mapID), String(roomID)]
        if let mapRevision { parts.append(String(mapRevision)) }
        return parts.joined(separator: ".")
    }

    public init?(id: String, name: String) {
        guard id.utf8.count <= 160 else { return nil }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (parts.count == 6 && parts[1] == "v1") || (parts.count == 7 && parts[1] == "v2") else { return nil }
        guard parts[0] == "freo-room",
              let productKey = Self.decode(parts[2]), let deviceID = Self.decode(parts[3]),
              let mapID = Self.positiveInteger(parts[4]), let roomID = Self.positiveInteger(parts[5]) else { return nil }
        var revision: UInt32?
        if parts.count == 7 {
            guard parts[6].utf8.count <= 10, let value = UInt32(parts[6]), String(value) == parts[6] else { return nil }
            revision = value
        }
        self.init(productKey: productKey, deviceID: deviceID, mapID: mapID, roomID: roomID, name: name, mapRevision: revision)
        guard isValid, self.id == id else { return nil }
    }

    /// Searches the actual names only. All ambiguous matches remain available
    /// for Siri to disambiguate; no aliases or room types are inferred.
    public static func matching(query: String, in references: [SiriRoomReference]) -> [SiriRoomReference] {
        let query = normalized(query)
        guard !query.isEmpty else { return [] }
        let matches = references.compactMap { reference -> (reference: SiriRoomReference, name: String, rank: Int)? in
            guard reference.isValid else { return nil }
            let name = normalized(reference.name)
            let rank: Int
            if name == query { rank = 0 }
            else if name.hasPrefix(query) { rank = 1 }
            else if name.contains(query) { rank = 2 }
            else { return nil }
            return (reference, name, rank)
        }
        return matches.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.reference.id != rhs.reference.id { return lhs.reference.id < rhs.reference.id }
            return lhs.reference.name < rhs.reference.name
        }.map(\.reference)
    }

    /// Validates against one freshly-read robot/map catalog. Returning only
    /// numeric room IDs is safe only after every reference shares that scope.
    /// Names can change without invalidating an otherwise identical reference.
    public static func validate(requested: [SiriRoomReference], against current: [SiriRoomReference]) throws -> [Int] {
        guard !requested.isEmpty else { throw ValidationError.emptySelection }
        guard requested.count <= 100 else { throw ValidationError.tooManyRooms }
        guard requested.allSatisfy(\.isValid) else { throw ValidationError.invalidReference }
        guard Set(requested.map(\.id)).count == requested.count else { throw ValidationError.duplicateSelection }
        guard !current.isEmpty, current.count <= 100, current.allSatisfy(\.isValid),
              Set(current.map(\.id)).count == current.count else { throw ValidationError.invalidCurrentCatalog }
        let scope = current[0].scope
        guard current.allSatisfy({ $0.scope == scope }), requested.allSatisfy({ $0.scope == scope }) else {
            throw ValidationError.scopeMismatch
        }
        let knownIDs = Set(current.map(\.id))
        guard requested.allSatisfy({ knownIDs.contains($0.id) }) else { throw ValidationError.staleReference }
        return requested.map(\.roomID)
    }

    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case emptySelection, tooManyRooms, invalidReference, duplicateSelection
        case invalidCurrentCatalog, scopeMismatch, staleReference

        public var errorDescription: String? {
            switch self {
            case .emptySelection: return "Choose at least one saved room."
            case .tooManyRooms: return "Choose no more than 100 rooms."
            case .invalidReference: return "A saved room reference is invalid. Choose the room again."
            case .duplicateSelection: return "A room was selected more than once. Choose each room only once."
            case .invalidCurrentCatalog: return "Reload the robot’s current rooms before using this shortcut."
            case .scopeMismatch: return "This room selection belongs to a different robot, map, or saved-map revision. Choose the current rooms again to update this shortcut."
            case .staleReference: return "A selected room is no longer on the current map. Choose the room again."
            }
        }
    }

    private struct Scope: Equatable {
        let productKey: String
        let deviceID: String
        let mapID: Int
        let mapRevision: UInt32?
    }

    private var scope: Scope { Scope(productKey: productKey, deviceID: deviceID, mapID: mapID, mapRevision: mapRevision) }
    private static let maximumID = 0x7fffffff

    private var isValid: Bool {
        (1...32).contains(productKey.utf8.count) && productKey.unicodeScalars.allSatisfy(Self.isASCIIAlphanumeric)
            && deviceID.utf8.count == 32 && deviceID.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (65...70).contains(scalar.value) || (97...102).contains(scalar.value)
            }
            && (1...Self.maximumID).contains(mapID) && (1...Self.maximumID).contains(roomID)
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func positiveInteger(_ text: String) -> Int? {
        guard text.utf8.count <= 10, let value = Int(text), (1...maximumID).contains(value), String(value) == text else { return nil }
        return value
    }

    private static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= 43,
              text.unicodeScalars.allSatisfy({ isASCIIAlphanumeric($0) || $0.value == 45 || $0.value == 95 }) else { return nil }
        let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), let value = String(data: data, encoding: .utf8), encode(value) == text else { return nil }
        return value
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.filter { !$0.isWhitespace })
    }
}

/// Names and scoped references for Siri indexing, never command authorization.
/// Read without a cloud/session round trip so the OS can expand trigger phrases
/// while the app is not running. Every start still validates the live map.
public struct SiriRoomCatalog: Sendable {
    private let directory: URL
    private struct Record: Codable { let version: Int; let rooms: [SiriRoomReference]; let aliases: [String: String]? }
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("FreoSiriRooms", isDirectory: true)
    }
    private var file: URL { directory.appendingPathComponent("rooms.json") }
    public func save(_ rooms: [SiriRoomReference]) throws {
        try validate(rooms)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ConnectorError.invalid("Invalid Siri room catalog directory.") }
        let previous = try? loadRecord()
        var aliases: [String: String] = [:]
        if let previous {
            let priorRooms = previous.rooms
            let eligible = priorRooms.filter { old in rooms.contains { sameMap($0, old) } }
            let oldNameCounts = Dictionary(grouping: eligible, by: { normalized($0.name) }).mapValues(\.count)
            let newByName = Dictionary(grouping: rooms.filter { new in eligible.contains { sameMap(new, $0) } }, by: { normalized($0.name) })
            for old in eligible where oldNameCounts[normalized(old.name)] == 1 {
                guard let candidates = newByName[normalized(old.name)], candidates.count == 1 else { continue }
                if old.id != candidates[0].id { aliases[old.id] = candidates[0].id }
            }
            // Carry older aliases forward only while their uniquely named room
            // still maps to the same robot and map.
            for (source, oldTarget) in previous.aliases ?? [:] {
                guard let old = priorRooms.first(where: { $0.id == oldTarget }),
                      let sourceRef = SiriRoomReference(id: source, name: old.name),
                      let candidates = newByName[normalized(old.name)], candidates.count == 1,
                      sameMap(sourceRef, candidates[0]), source != candidates[0].id else { continue }
                aliases[source] = candidates[0].id
            }
        }
        guard aliases.count <= 1000 else { throw ConnectorError.invalid("Too many saved shortcut room references to migrate safely.") }
        let data = try JSONEncoder().encode(Record(version: 2, rooms: rooms, aliases: aliases))
        guard data.count <= 65_536 else { throw ConnectorError.invalid("Siri room catalog is too large.") }
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var url = directory, values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    public func load() throws -> [SiriRoomReference] {
        try loadRecord().rooms
    }
    /// Distinguishes a current catalog from a legacy-format catalog even when
    /// the visible room list is identical. This ensures room-map refreshes
    /// upgrade old records and rebuild migration aliases instead of returning
    /// early on a rooms-only equality check.
    public func isCurrent(_ rooms: [SiriRoomReference]) throws -> Bool {
        let record = try loadRecord()
        return record.version == 2 && record.rooms == rooms
    }
    /// Resolves a shortcut's old entity ID only when its previous room name
    /// still identifies exactly one room on the same robot and map.
    public func resolve(identifier: String, current: [SiriRoomReference]) throws -> SiriRoomReference? {
        if let direct = current.first(where: { $0.id == identifier }) { return direct }
        let record = try loadRecord()
        guard let targetID = record.aliases?[identifier] else { return nil }
        return current.first(where: { $0.id == targetID })
    }
    /// Resolves saved Shortcut selections against the refreshed catalog. A
    /// room is migrated only through a unique same-device/map alias created
    /// by `save`; missing or ambiguous rooms remain errors.
    public func resolve(_ requested: [SiriRoomReference], current: [SiriRoomReference]) throws -> [SiriRoomReference] {
        guard !requested.isEmpty else { throw SiriRoomReference.ValidationError.emptySelection }
        guard requested.count <= 100 else { throw SiriRoomReference.ValidationError.tooManyRooms }
        guard Set(requested.map(\.id)).count == requested.count else { throw SiriRoomReference.ValidationError.duplicateSelection }
        var resolved: [SiriRoomReference] = []
        resolved.reserveCapacity(requested.count)
        for reference in requested {
            guard let parsed = SiriRoomReference(id: reference.id, name: reference.name),
                  parsed.productKey == reference.productKey, parsed.deviceID == reference.deviceID,
                  parsed.mapID == reference.mapID, parsed.roomID == reference.roomID,
                  parsed.mapRevision == reference.mapRevision,
                  let room = try resolve(identifier: reference.id, current: current) else {
                throw SiriRoomReference.ValidationError.staleReference
            }
            resolved.append(room)
        }
        _ = try SiriRoomReference.validate(requested: resolved, against: current)
        return resolved
    }
    private func loadRecord() throws -> Record {
        guard FileManager.default.fileExists(atPath: file.path) else { return Record(version: 2, rooms: [], aliases: [:]) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, (1...65_536).contains(size.intValue) else {
            throw ConnectorError.invalid("Invalid Siri room catalog.")
        }
        let data = try Data(contentsOf: file)
        guard data.count <= 65_536 else { throw ConnectorError.invalid("Siri room catalog is too large.") }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1 || record.version == 2 else { throw ConnectorError.invalid("Unknown Siri room catalog version.") }
        try validate(record.rooms)
        let aliases = record.aliases ?? [:]
        guard aliases.count <= 1000, aliases.allSatisfy({ source, target in
            guard let sourceRef = SiriRoomReference(id: source, name: "Room"),
                  let targetRef = record.rooms.first(where: { $0.id == target }) else { return false }
            return sameMap(sourceRef, targetRef) && source != target
        }) else { throw ConnectorError.invalid("Invalid Siri room aliases.") }
        return Record(version: record.version, rooms: record.rooms, aliases: aliases)
    }
    public func remove() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func validate(_ rooms: [SiriRoomReference]) throws {
        _ = try SiriRoomReference.validate(requested: rooms, against: rooms)
        guard rooms.allSatisfy({ (1...256).contains($0.name.utf8.count) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ConnectorError.invalid("Invalid Siri room name.")
        }
    }
    private func sameMap(_ lhs: SiriRoomReference, _ rhs: SiriRoomReference) -> Bool {
        lhs.productKey == rhs.productKey && lhs.deviceID == rhs.deviceID && lhs.mapID == rhs.mapID
    }
    private func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace }
    }
}
