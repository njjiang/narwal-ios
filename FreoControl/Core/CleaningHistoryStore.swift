import Foundation

/// A locally observed route window, not a certified complete robot cleaning.
/// No Narwal task/run identifier is exposed by the verified map schema.
public struct CleaningRun: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    /// First observation time; not the robot's cleaning start time.
    public let startedAt: Date
    public let updatedAt: Date
    public let floorplan: Floorplan
    /// Latest cumulative response, never a concatenation of separate responses.
    public let trajectory: RobotTrajectory
    /// Task mode and targets reported during capture, never the current UI picker.
    public let modeName: String?
    public let roomNames: [String]
    public let partialReason: String
    public let observationCount: Int
    /// Present only for a verified, scoped Narwal saved-record response.
    public let cloudRecordID: String?
    /// Local retention clock, distinct from the historical cleaning dates.
    public let importedAt: Date?
    public var isCloudRecord: Bool { cloudRecordID != nil }
    var retainedAt: Date { importedAt ?? updatedAt }

    public init(id: UUID, startedAt: Date, updatedAt: Date, floorplan: Floorplan,
                trajectory: RobotTrajectory, modeName: String? = nil, roomNames: [String] = [],
                partialReason: String, observationCount: Int = 1, cloudRecordID: String? = nil, importedAt: Date? = nil) {
        self.id = id; self.startedAt = startedAt; self.updatedAt = updatedAt; self.floorplan = floorplan
        self.trajectory = trajectory; self.modeName = modeName; self.roomNames = roomNames
        self.partialReason = partialReason; self.observationCount = observationCount
        self.cloudRecordID = cloudRecordID; self.importedAt = importedAt
    }
}

/// Private, bounded local storage. It contains floorplans and routes, never
/// account tokens, passwords, response envelopes, or raw protocol payloads.
/// The caller must change windowID on foreground/session/device/task changes.
/// Archive writes do not send requests to the robot or any network service.
public actor CleaningHistoryStore {
    public static let partialCaptureReason = "Observed while the app was open. The route may include earlier movement; cleaning identity and completion are unverified."
    public static let cloudSavedReason = "Saved by Narwal. This saved route does not by itself verify exact cleaning coverage."
    public static let maximumObservationGap: TimeInterval = 45
    private static let recordLimit = 16 * 1024 * 1024
    private let suppliedDirectory: URL?
    private let maximumRecords: Int
    private let maximumBytes: Int
    private let retention: TimeInterval
    private var records: [CleaningRun]?
    private var activeWindow: UUID?
    private var activeRun: UUID?

    public init(directory: URL? = nil, maximumRecords: Int = 20,
                maximumBytes: Int = 48 * 1024 * 1024, retentionDays: Int = 30) {
        self.suppliedDirectory = directory
        self.maximumRecords = min(100, max(1, maximumRecords))
        self.maximumBytes = min(128 * 1024 * 1024, max(1024, maximumBytes))
        self.retention = TimeInterval(min(365, max(1, retentionDays))) * 86_400
    }

    public func load() throws -> [CleaningRun] {
        if let records { return records }
        let directory = try privateDirectory()
        let manager = FileManager.default
        var result: [CleaningRun] = []
        var totalBytes = 0
        let files = try managedFiles(in: directory).sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left > right
        }
        // Enumerating the private directory is bounded by our retention on
        // each write. Do not decode untrusted oversized/corrupt/symlink files.
        for file in files {
            do {
                let attrs = try manager.attributesOfItem(atPath: file.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      let count = attrs[.size] as? NSNumber, count.intValue > 0,
                      count.intValue <= Self.recordLimit, count.intValue <= maximumBytes - totalBytes,
                      result.count < maximumRecords else { continue }
                let data = try Data(contentsOf: file)
                guard data.count == count.intValue else { continue }
                let record = try JSONDecoder().decode(Record.self, from: data)
                guard record.version == 1, file.deletingPathExtension().lastPathComponent.lowercased() == record.run.id.uuidString.lowercased() else { continue }
                try Self.validate(record.run)
                guard record.run.retainedAt >= Date().addingTimeInterval(-retention),
                      record.run.retainedAt <= Date().addingTimeInterval(300) else { continue }
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
                var privateFile = file; try privateFile.setResourceValues(excluded)
                result.append(record.run); totalBytes += data.count
            } catch { continue }
        }
        records = Self.sorted(result)
        // Never resume a persisted capture after a process restart/load.
        activeWindow = nil; activeRun = nil
        try prune(directory: directory, keeping: Set(result.map(\.id)))
        return records!
    }

    /// Labels describe a fresh, scoped robot task read during capture. They do
    /// not certify that all points of a cumulative route belong to that task.
    public func observe(snapshot: MapSnapshot, trajectory: RobotTrajectory, windowID: UUID,
                        modeName: String? = nil, roomNames: [String] = []) throws -> [CleaningRun] {
        try observe(snapshot: snapshot, trajectory: trajectory, windowID: windowID,
                    modeName: modeName, roomNames: roomNames, maximumMapAge: 0)
    }

    /// A verified push uses an earlier baseline map from the same short lease.
    /// Keep the map's actual capture time; do not fabricate a simultaneous read.
    public func observeLive(snapshot: MapSnapshot, trajectory: RobotTrajectory, windowID: UUID,
                            modeName: String? = nil, roomNames: [String] = []) throws -> [CleaningRun] {
        try observe(snapshot: snapshot, trajectory: trajectory, windowID: windowID,
                    modeName: modeName, roomNames: roomNames, maximumMapAge: 60)
    }

    private func observe(snapshot: MapSnapshot, trajectory: RobotTrajectory, windowID: UUID,
                         modeName: String?, roomNames: [String], maximumMapAge: TimeInterval) throws -> [CleaningRun] {
        if records == nil { _ = try load() }
        guard !trajectory.isSimulated else { return records! }
        guard trajectory.productKey == snapshot.productKey, trajectory.deviceID == snapshot.deviceID,
              trajectory.mapID == snapshot.mapID, trajectory.mapVersion == snapshot.mapVersion,
              trajectory.editVersion == snapshot.editVersion,
              trajectory.capturedAt.timeIntervalSince(snapshot.capturedAt) >= 0,
              trajectory.capturedAt.timeIntervalSince(snapshot.capturedAt) <= maximumMapAge else {
            throw Self.invalid("Route history does not match the received robot map.")
        }
        guard trajectory.unavailableReason == nil, trajectory.points.count >= 2,
              trajectory.points.dropFirst().contains(where: { $0 != trajectory.points.first! }) else {
            activeWindow = nil; activeRun = nil; return records!
        }
        // Pose update time establishes response freshness only, not route/run
        // freshness. Missing/old timestamps cannot start a history record.
        guard let timestamp = trajectory.deviceTimestampMilliseconds,
              abs(Double(timestamp) / 1000 - trajectory.capturedAt.timeIntervalSince1970) <= 90 else {
            activeWindow = nil; activeRun = nil; return records!
        }
        var previous: CleaningRun?
        if activeWindow == windowID, let id = activeRun {
            previous = records!.first { $0.id == id }
        }
        if let old = previous, !Self.canContinue(old, snapshot: snapshot, trajectory: trajectory,
                                               modeName: modeName, roomNames: roomNames) {
            previous = nil
        }
        activeWindow = windowID
        if previous == nil, records!.contains(where: {
            !$0.isCloudRecord && Self.sameGeometry($0.floorplan, snapshot.floorplan) && Self.sameScope($0.trajectory, trajectory) &&
            $0.trajectory.points == trajectory.points && $0.trajectory.segments == trajectory.segments
        }) {
            // Revisiting a stationary old cumulative path is not a new clean.
            activeRun = nil; return records!
        }
        let run = CleaningRun(id: previous?.id ?? UUID(), startedAt: previous?.startedAt ?? trajectory.capturedAt,
            updatedAt: trajectory.capturedAt, floorplan: previous?.floorplan ?? snapshot.floorplan,
            trajectory: trajectory, modeName: modeName ?? previous?.modeName,
            roomNames: roomNames.isEmpty ? previous?.roomNames ?? [] : roomNames,
            partialReason: Self.partialCaptureReason, observationCount: (previous?.observationCount ?? 0) + 1)
        let retained = try persist(run)
        activeRun = retained.contains(where: { $0.id == run.id }) ? run.id : nil
        return retained
    }

    /// Import a server-saved route by its stable device+record identity. This
    /// never resumes an observation window or guesses a historical pose time.
    public func importCloud(run: CleaningRun) throws -> [CleaningRun] {
        if records == nil { _ = try load() }
        guard run.isCloudRecord else { throw Self.invalid("This is not a Narwal saved route.") }
        return try persist(run)
    }

    private func persist(_ run: CleaningRun) throws -> [CleaningRun] {
        try Self.validate(run)
        let data = try JSONEncoder().encode(Record(version: 1, run: run))
        guard data.count <= Self.recordLimit, data.count <= maximumBytes else {
            throw Self.invalid("The observed route exceeds the private history storage limit.")
        }
        let directory = try privateDirectory(), file = url(run.id, in: directory)
        if FileManager.default.fileExists(atPath: file.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else {
                throw Self.invalid("The private route history file is unavailable.")
            }
        }
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var privateFile = file; try privateFile.setResourceValues(excluded)
        records!.removeAll { $0.id == run.id }; records!.append(run)
        records = records!.filter { $0.retainedAt >= Date().addingTimeInterval(-retention) }.sorted {
            $0.retainedAt == $1.retainedAt ? $0.id.uuidString < $1.id.uuidString : $0.retainedAt > $1.retainedAt
        }
        var retained: [CleaningRun] = [], bytes = 0
        for item in records! {
            let attrs = try FileManager.default.attributesOfItem(atPath: url(item.id, in: directory).path)
            let count = (attrs[.size] as? NSNumber)?.intValue ?? Self.recordLimit + 1
            if retained.count < maximumRecords, count <= maximumBytes - bytes {
                retained.append(item); bytes += count
            }
        }
        retained = Self.sorted(retained)
        records = retained
        try prune(directory: directory, keeping: Set(retained.map(\.id)))
        return retained
    }

    public func delete(id: UUID) throws -> [CleaningRun] {
        if records == nil { _ = try load() }
        let file = url(id, in: try privateDirectory())
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        records!.removeAll { $0.id == id }
        if activeRun == id { activeRun = nil; activeWindow = nil }
        return records!
    }

    public func clear() throws {
        try prune(directory: privateDirectory(), keeping: [])
        records = []; activeRun = nil; activeWindow = nil
    }

    private struct Record: Codable { let version: Int; let run: CleaningRun }

    private static func canContinue(_ previous: CleaningRun, snapshot: MapSnapshot,
                                    trajectory: RobotTrajectory, modeName: String?, roomNames: [String]) -> Bool {
        let old = previous.trajectory
        guard sameScope(old, trajectory), sameGeometry(previous.floorplan, snapshot.floorplan),
              (previous.modeName == nil || modeName == nil || previous.modeName == modeName),
              (previous.roomNames.isEmpty || roomNames.isEmpty || previous.roomNames == roomNames),
              trajectory.capturedAt > previous.updatedAt,
              trajectory.capturedAt.timeIntervalSince(previous.updatedAt) <= maximumObservationGap,
              let oldTime = old.deviceTimestampMilliseconds, let newTime = trajectory.deviceTimestampMilliseconds,
              newTime >= oldTime, let oldSequence = old.sequenceID, let newSequence = trajectory.sequenceID,
              newSequence >= oldSequence, trajectory.points.count >= old.points.count,
              Array(trajectory.points.prefix(old.points.count)) == old.points else { return false }
        // A type change on a prior segment may indicate replacement/reset even
        // if coordinates happen to share a prefix. Never silently reinterpret.
        for segment in old.segments {
            guard let current = trajectory.segments.first(where: { $0.id == segment.id }),
                  current.typeCode == segment.typeCode,
                  Array(current.points.prefix(segment.points.count)) == segment.points else { return false }
        }
        return true
    }

    private static func sameGeometry(_ a: Floorplan, _ b: Floorplan) -> Bool {
        guard a.mapID == b.mapID, a.mapRevision == b.mapRevision, a.width == b.width,
              a.height == b.height, a.resolution == b.resolution, a.rooms == b.rooms,
              a.pixels.count == b.pixels.count else { return false }
        // Offline captures of the same saved map during both verified cleaning
        // windows changed these runtime bits. This allowance is ONLY for route
        // grouping, never map edits. Room labels, walls, unreachable cells and
        // every other unknown bit remain exact; the original raster is frozen.
        let observedRuntimeMask: UInt32 = 0x1001_0043
        return zip(a.pixels, b.pixels).allSatisfy { ($0 ^ $1) & ~observedRuntimeMask == 0 }
    }

    private static func sameScope(_ a: RobotTrajectory, _ b: RobotTrajectory) -> Bool {
        a.productKey == b.productKey && a.deviceID == b.deviceID && a.mapID == b.mapID &&
        a.mapVersion == b.mapVersion && a.editVersion == b.editVersion && a.isSimulated == b.isSimulated
    }
    private static func sorted(_ records: [CleaningRun]) -> [CleaningRun] {
        records.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }
    private static func validate(_ run: CleaningRun) throws {
        let map = run.floorplan, trajectory = run.trajectory
        func validText(_ text: String, max: Int) -> Bool {
            text.utf8.count <= max && !text.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
        }
        guard !trajectory.isSimulated, (1...32).contains(trajectory.productKey.utf8.count),
              trajectory.productKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              trajectory.deviceID.utf8.count == 32,
              trajectory.deviceID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              map.mapID > 0, trajectory.mapID == map.mapID, trajectory.editVersion == map.mapRevision,
              (1...4096).contains(map.width), (1...4096).contains(map.height), map.width <= 1_000_000 / map.height,
              map.pixels.count == map.width * map.height, map.rooms.count <= 100,
              Set(map.rooms.map(\.id)).count == map.rooms.count,
              map.rooms.allSatisfy({ (1...255).contains($0.id) && validText($0.name, max: 256) }),
              trajectory.points.count <= 100_000, trajectory.segments.count <= 2049,
              run.startedAt.timeIntervalSince1970.isFinite, run.updatedAt.timeIntervalSince1970.isFinite,
              run.startedAt <= run.updatedAt, trajectory.capturedAt == run.updatedAt,
              run.updatedAt <= Date().addingTimeInterval(300),
              run.updatedAt.timeIntervalSince(run.startedAt) <= 365 * 86_400,
              (1...1_000_000).contains(run.observationCount),
              run.modeName.map({ validText($0, max: 100) }) ?? true,
              run.roomNames.count <= 100, run.roomNames.allSatisfy({ validText($0, max: 256) }),
              trajectory.unavailableReason == nil else { throw invalid("Invalid private route history record.") }
        if let cloudID = run.cloudRecordID {
            guard let integerID = Int64(cloudID), integerID > 0, String(integerID) == cloudID,
                  run.id == NarwalHistoryCodec.stableID(productKey: trajectory.productKey, deviceID: trajectory.deviceID, recordID: cloudID),
                  run.partialReason == cloudSavedReason, let imported = run.importedAt,
                  imported.timeIntervalSince1970.isFinite, imported <= Date().addingTimeInterval(300),
                  imported >= run.updatedAt, trajectory.deviceTimestampMilliseconds == nil,
                  trajectory.sequenceID == nil, trajectory.editVersion == nil, map.mapRevision == nil,
                  trajectory.pose == nil,
                  run.observationCount == 1 else { throw invalid("Invalid saved Narwal route record.") }
        } else {
            guard run.importedAt == nil, run.partialReason == partialCaptureReason,
                  trajectory.deviceTimestampMilliseconds.map({
                      abs(Double($0) / 1000 - trajectory.capturedAt.timeIntervalSince1970) <= 90
                  }) ?? false else { throw invalid("Invalid observed route freshness metadata.") }
        }
        func validPoint(_ point: RobotPathPoint) -> Bool {
            point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0 &&
            point.x <= Double(map.width) && point.y <= Double(map.height)
        }
        guard trajectory.points.allSatisfy(validPoint), trajectory.pose.map({ validPoint($0.point) }) ?? true else {
            throw invalid("Invalid private route history coordinates.")
        }
        var lastEnd: Int?
        for segment in trajectory.segments {
            guard segment.id >= 0, segment.typeCode >= 0, segment.typeCode <= Int(Int32.max),
                  segment.points.count >= 2, segment.id <= trajectory.points.count,
                  segment.points.count <= trajectory.points.count - segment.id,
                  lastEnd.map({ $0 == segment.id }) ?? (segment.id == 0),
                  Array(trajectory.points[segment.id..<segment.id + segment.points.count]) == segment.points else {
                throw invalid("Invalid private route history segments.")
            }
            lastEnd = segment.id + segment.points.count - 1
        }
        guard trajectory.points.count < 2 || lastEnd == trajectory.points.count - 1 else {
            throw invalid("Incomplete private route history segments.")
        }
    }
    private func privateDirectory() throws -> URL {
        let manager = FileManager.default
        let directory = try suppliedDirectory ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FreoRouteHistory", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try manager.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw Self.invalid("The private route history location is unavailable.") }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(excluded)
        return directory
    }
    private func url(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }
    private func managedFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
    }
    private func prune(directory: URL, keeping: Set<UUID>) throws {
        for file in try managedFiles(in: directory) {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !keeping.contains(id) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    private static func invalid(_ message: String) -> ConnectorError { .invalid(message) }
}
