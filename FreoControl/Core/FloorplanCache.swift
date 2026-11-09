import Foundation
import CryptoKit

/// A last-known map for display only. Its timestamp never authorizes a command
/// or establishes fresh robot status/position.
public struct CachedFloorplan: Equatable, Sendable {
    public let floorplan: Floorplan
    public let cachedAt: Date
}

/// One bounded, private map per robot. No routes, account tokens or passwords
/// are persisted here, and cached maps are excluded from device backups.
public actor FloorplanCache {
    private struct Record: Codable {
        let version: Int
        let productKey: String
        let deviceID: String
        let cachedAt: Date
        let floorplan: Floorplan
    }

    private let suppliedDirectory: URL?
    private let maximumBytes: Int
    private static let maximumDevices = 8

    public init(directory: URL? = nil, maximumBytes: Int = 16 * 1024 * 1024) {
        suppliedDirectory = directory
        self.maximumBytes = min(16 * 1024 * 1024, max(256, maximumBytes))
    }

    public func save(floorplan: Floorplan, device: RobotDevice) throws {
        guard Self.valid(device), Self.valid(floorplan) else {
            throw ConnectorError.invalid("The floorplan cannot be saved locally.")
        }
        let directory = try privateDirectory(), file = path(device, in: directory)
        // A status refresh normally returns identical room geometry. Avoid
        // rewriting the same map to disk on every observation.
        if try load(device: device)?.floorplan == floorplan { return }
        let record = Record(version: 1, productKey: device.productKey, deviceID: device.id,
                            cachedAt: Date(), floorplan: floorplan)
        let data = try JSONEncoder().encode(record)
        guard data.count <= maximumBytes else {
            throw ConnectorError.invalid("The floorplan exceeds its local storage limit.")
        }
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: [.atomic])
        #endif
        try protect(file)
        try prune(directory: directory, keeping: file)
    }

    public func load(device: RobotDevice) throws -> CachedFloorplan? {
        guard Self.valid(device) else { return nil }
        let file = path(device, in: try privateDirectory())
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return nil }
        let attributes = try manager.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let count = attributes[.size] as? NSNumber,
              count.intValue > 0, count.intValue <= maximumBytes else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count == count.intValue,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.productKey == device.productKey,
              record.deviceID == device.id, Self.valid(record.floorplan),
              record.cachedAt.timeIntervalSince1970.isFinite,
              record.cachedAt.timeIntervalSince1970 > 0,
              record.cachedAt <= Date().addingTimeInterval(300) else { return nil }
        try protect(file)
        return CachedFloorplan(floorplan: record.floorplan, cachedAt: record.cachedAt)
    }

    private func path(_ device: RobotDevice, in directory: URL) -> URL {
        let identity = "\(device.productKey.utf8.count):\(device.productKey)\(device.id)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    private func privateDirectory() throws -> URL {
        let manager = FileManager.default
        var directory = try suppliedDirectory ?? manager.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FreoFloorplanCache", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ConnectorError.invalid("The local floorplan cache is unavailable.")
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var file = url, values = URLResourceValues(); values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }

    private func prune(directory: URL, keeping current: URL) throws {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
            .filter { file in
                let name = file.deletingPathExtension().lastPathComponent
                return file.pathExtension == "json" && name.count == 64 &&
                    name.allSatisfy { "0123456789abcdef".contains($0) } &&
                    (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
            }
        for file in files.filter({ $0 != current }).prefix(max(0, files.count - Self.maximumDevices)) {
            try manager.removeItem(at: file)
        }
    }

    private static func valid(_ device: RobotDevice) -> Bool {
        !device.productKey.isEmpty && device.productKey.utf8.count <= 256 &&
        !device.id.isEmpty && device.id.utf8.count <= 256
    }

    private static func valid(_ map: Floorplan) -> Bool {
        (1...Int(Int32.max)).contains(map.mapID) && map.width > 0 && map.height > 0 &&
        map.width <= 1_000_000 / map.height && map.pixels.count == map.width * map.height &&
        map.rooms.count <= 255 && Set(map.rooms.map(\.id)).count == map.rooms.count &&
        map.rooms.allSatisfy { (1...255).contains($0.id) && !$0.name.isEmpty && $0.name.utf8.count <= 512 } &&
        (map.resolution.map { (1...1_000).contains($0) } ?? true)
    }
}
