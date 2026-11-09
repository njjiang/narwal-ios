import Foundation

/// Local evidence only. No restore endpoint is known or implemented.
enum MapSnapshotStore {
    static let maximumReadbackRecords = 32
    private static let readbackLock = NSLock()
    private struct Record: Codable {
        let formatVersion: Int
        let purpose: String
        let productKey: String
        let deviceID: String
        let mapID: Int
        let mapVersion: UInt32
        let editVersion: UInt32
        let capturedAt: Date
        let staticMapPayload: Data
    }

    static func preserve(_ snapshot: MapSnapshot, directory suppliedDirectory: URL? = nil) throws -> URL {
        try preserve(snapshot, directory: suppliedDirectory,
                     purpose: "Exact map snapshot; restoration is not implemented.")
    }

    /// Keep rejected readbacks as well as accepted ones. This separate, bounded
    /// directory never prunes the original pre-write snapshots.
    static func preserveReadback(_ snapshot: MapSnapshot, directory suppliedDirectory: URL? = nil) throws -> URL {
        readbackLock.lock(); defer { readbackLock.unlock() }
        let manager = FileManager.default
        let directory = try suppliedDirectory ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FreoMapSnapshots/Readbacks", isDirectory: true)
        let url = try preserve(snapshot, directory: directory,
            purpose: "Post-edit map readback before validation; restoration is not implemented.")
        let records = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
            }
        // Protect the just-captured evidence even if filesystem timestamps tie.
        let removable = records.filter { $0.lastPathComponent != url.lastPathComponent }
        for old in removable.prefix(max(0, records.count - maximumReadbackRecords)) {
            try manager.removeItem(at: old)
        }
        return url
    }

    /// Keep the firmware's exact rejection beside the pre-write map for diagnosis.
    /// Operation descriptions contain map edits only, never account credentials.
    static func preserveFailure(snapshotURL: URL, operations: [RoomMapOperation], error: Error) throws {
        struct Failure: Encodable {
            let capturedAt: Date
            let operations: [String]
            let message: String
        }
        let failure = Failure(capturedAt: Date(), operations: operations.map { String(describing: $0) },
                              message: error.localizedDescription)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(failure)
        let url = snapshotURL.deletingPathExtension().appendingPathExtension("failure.json")
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var file = url, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }

    private static func preserve(_ snapshot: MapSnapshot, directory suppliedDirectory: URL?, purpose: String) throws -> URL {
        let manager = FileManager.default
        let directory = try suppliedDirectory ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("FreoMapSnapshots", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ConnectorError.invalid("The private map snapshot location is unavailable.") }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(excluded)
        let record = Record(formatVersion: 1, purpose: purpose,
                            productKey: snapshot.productKey, deviceID: snapshot.deviceID, mapID: snapshot.mapID,
                            mapVersion: snapshot.mapVersion, editVersion: snapshot.editVersion,
                            capturedAt: snapshot.capturedAt, staticMapPayload: snapshot.staticMapPayload)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= 2 * 1024 * 1024 else { throw ConnectorError.invalid("The map snapshot exceeds its storage limit.") }
        let url = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var file = url; try file.setResourceValues(excluded)
        return url
    }
}
