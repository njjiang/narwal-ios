#if DEBUG || FREO_DIAGNOSTIC_TEST
import Foundation
import Darwin
import CryptoKit

/// Explicit, one-shot developer diagnostics. This is not a network listener or
/// an alternate login path. It uses only this app's unexpired remembered session.
struct FreoDiagnosticRequest: Decodable {
    struct Source: Codable { let id: Int; let name: String }
    struct Rectangle: Codable {
        let minX: Int; let minY: Int; let maxXExclusive: Int; let maxYExclusive: Int
        var grid: RoomGridRectangle {
            RoomGridRectangle(minX: minX, minY: minY, maxXExclusive: maxXExclusive, maxYExclusive: maxYExclusive)
        }
    }
    struct Partition: Decodable {
        let expectedDeviceDigest: String
        let mapID: Int
        let mapVersion: UInt32
        let editVersion: UInt32
        let sources: [Source]
        let rectangle: Rectangle
        let targetName: String
        let remainderName: String
        let expectedRemainingStage: String
        let usesDrawnBox: Bool?
    }
    let version: Int
    let id: String
    let createdAt: Date
    let operation: String
    let partition: Partition?

    static func decode(_ data: Data, expectedID: String, now: Date = Date()) throws -> Self {
        guard data.count <= 16384 else { throw FreoDiagnosticFailure.invalidRequest }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let request: Self
        do { request = try decoder.decode(Self.self, from: data) }
        catch { throw FreoDiagnosticFailure.invalidRequest }
        guard request.version == 1, request.id == expectedID,
              canonicalID(request.id) != nil,
              request.createdAt.timeIntervalSince(now) <= 5,
              now.timeIntervalSince(request.createdAt) <= 600 else { throw FreoDiagnosticFailure.invalidRequest }
        switch request.operation {
        case "inspect":
            guard request.partition == nil else { throw FreoDiagnosticFailure.invalidRequest }
        case "partition":
            guard let part = request.partition,
                  part.expectedDeviceDigest.utf8.count == 64,
                  part.expectedDeviceDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  (1...Int(UInt32.max)).contains(part.mapID),
                  (1...8).contains(part.sources.count),
                  Set(part.sources.map(\.id)).count == part.sources.count,
                  part.sources.allSatisfy({ (1...255).contains($0.id) }),
                  RoomPartitionRemainingStage(rawValue: part.expectedRemainingStage) != nil,
                  part.rectangle.minX >= 0, part.rectangle.minY >= 0,
                  part.rectangle.maxXExclusive > part.rectangle.minX,
                  part.rectangle.maxYExclusive > part.rectangle.minY,
                  part.rectangle.maxXExclusive <= 100000,
                  part.rectangle.maxYExclusive <= 100000 else { throw FreoDiagnosticFailure.invalidRequest }
            for name in part.sources.map(\.name) + [part.targetName, part.remainderName] {
                try NarwalCodec.validateRoomName(name)
                guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw FreoDiagnosticFailure.invalidRequest
                }
            }
            guard part.targetName.compare(part.remainderName, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame else {
                throw FreoDiagnosticFailure.invalidRequest
            }
        default: throw FreoDiagnosticFailure.invalidRequest
        }
        return request
    }
    static func canonicalID(_ value: String) -> String? {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return nil }
        return value
    }
    static func invocationID(arguments: [String]) throws -> String? {
        let positions = arguments.indices.filter { arguments[$0] == "--freo-diagnostic-request" }
        guard !positions.isEmpty else { return nil }
        guard positions.count == 1, let position = positions.first, position + 1 < arguments.count,
              let id = canonicalID(arguments[position + 1]) else { throw FreoDiagnosticFailure.invalidRequest }
        return id
    }
}

enum FreoDiagnosticFailure: Error {
    case invalidRequest, unavailableFiles, alreadyClaimed, noSavedSession, ambiguousRobot, deviceMismatch, baselineMismatch, notStandby
    var message: String {
        switch self {
        case .invalidRequest: return "The diagnostic request is invalid or more than ten minutes old."
        case .unavailableFiles: return "The private diagnostic request or response file is unavailable."
        case .alreadyClaimed: return "This request was already consumed. It was not run again."
        case .noSavedSession: return "No valid remembered session is available. Sign in through the app."
        case .ambiguousRobot: return "Exactly one supported Freo X Ultra must be discovered on the account."
        case .deviceMismatch: return "The restored robot does not match the robot reviewed for this request. Run a fresh inspection before preparing another edit."
        case .baselineMismatch: return "The current map, source room names, or saved divider stage differs from the reviewed request."
        case .notStandby: return "The robot must be on standby and not paused before changing room boundaries."
        }
    }
}

struct FreoDiagnosticResponse: Encodable {
    struct Status: Encodable {
        let battery: Double?; let workingCode: Int?; let isPaused: Bool?
        let stationContactCode: Int?; let reportedSuctionCode: Int?
        let label: String; let reportedSuctionLabel: String?
        init(_ status: RobotStatus) {
            battery = status.battery; workingCode = status.workingCode; isPaused = status.isPaused
            stationContactCode = status.stationContactCode; reportedSuctionCode = status.reportedSuctionCode
            label = status.label; reportedSuctionLabel = status.reportedSuctionLabel
        }
    }
    struct Map: Encodable {
        let mapID: Int; let mapVersion: UInt32; let editVersion: UInt32
        let width: Int; let height: Int; let maximumRoomCount: Int?
        let rooms: [FreoDiagnosticRequest.Source]
        init(_ snapshot: MapSnapshot) {
            mapID = snapshot.mapID; mapVersion = snapshot.mapVersion; editVersion = snapshot.editVersion
            width = snapshot.floorplan.width; height = snapshot.floorplan.height
            maximumRoomCount = snapshot.maximumRoomCount
            rooms = snapshot.floorplan.rooms.map { .init(id: $0.id, name: $0.name) }
        }
    }
    struct CurrentTask: Encodable {
        struct Sample: Encodable { let roomID: Int?; let parameters: [Int: UInt64]; let settings: [String] }
        let resultCode: Int; let mapID: Int?; let taskType: Int?; let samples: [Sample]
        init(_ plan: CleaningTaskSnapshot) {
            resultCode = plan.resultCode; mapID = plan.mapID; taskType = plan.taskType
            samples = plan.samples.map { .init(roomID: $0.roomID, parameters: $0.parameters, settings: $0.reportedSettings) }
        }
    }
    let version = 1
    let id: String
    var operation: String?
    var deviceDigest: String?
    var state = "claimed"
    var progress: String?
    var status: Status?
    var map: Map?
    var currentTask: CurrentTask?
    var remainingStage: String?
    var snapshotFilenames = [String]()
    var attemptedOperationBatches = 0
    var completedSteps: Int?
    var mayHaveChanged = false
    var recoveryReadbackUnavailable = false
    var error: String?
    var updatedAt = Date()
}

/// Claim files are deliberately never pruned: a UUID cannot become executable
/// again after a crash, failed readback, or expired request. Use a new reviewed ID.
struct FreoDiagnosticFiles {
    let directory: URL
    init(directory: URL? = nil) throws {
        let manager = FileManager.default
        self.directory = try directory ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FreoDiagnostics", isDirectory: true)
        try manager.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: self.directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw FreoDiagnosticFailure.unavailableFiles }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folder = self.directory; try folder.setResourceValues(excluded)
    }
    func claimAndRead(id: String) throws -> Data {
        guard FreoDiagnosticRequest.canonicalID(id) != nil else { throw FreoDiagnosticFailure.invalidRequest }
        let marker = directory.appendingPathComponent(id + ".claimed")
        let claim = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard claim >= 0 else {
            if errno == EEXIST { throw FreoDiagnosticFailure.alreadyClaimed }
            throw FreoDiagnosticFailure.unavailableFiles
        }
        // A crash after this durable marker is never permission to replay.
        let persisted = fsync(claim); close(claim)
        guard persisted == 0 else { throw FreoDiagnosticFailure.unavailableFiles }
        let request = directory.appendingPathComponent(id + ".request.json")
        let descriptor = open(request.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FreoDiagnosticFailure.unavailableFiles }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 16384,
              let data = try handle.read(upToCount: 16385), data.count <= 16384 else {
            throw FreoDiagnosticFailure.unavailableFiles
        }
        return data
    }
    func write(_ response: FreoDiagnosticResponse) throws {
        guard FreoDiagnosticRequest.canonicalID(response.id) != nil else { throw FreoDiagnosticFailure.invalidRequest }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        guard data.count <= 256 * 1024 else { throw FreoDiagnosticFailure.unavailableFiles }
        let destination = directory.appendingPathComponent(response.id + ".response.json")
        #if os(iOS)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: destination, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var file = destination; try file.setResourceValues(excluded)
    }
}

@MainActor
final class FreoDiagnosticContext {
    let files: FreoDiagnosticFiles
    var response: FreoDiagnosticResponse
    init(files: FreoDiagnosticFiles, id: String) { self.files = files; response = .init(id: id) }
    func save() throws { response.updatedAt = Date(); try files.write(response) }
    func progress(_ text: String) throws { response.progress = text; try save() }
    func markAttempt(_ status: RobotStatus) throws {
        response.status = .init(status)
        response.attemptedOperationBatches += 1
        response.mayHaveChanged = true
        try save()
    }
    func record(_ snapshot: MapSnapshot, filename: String? = nil) throws {
        response.map = .init(snapshot)
        if let filename, !response.snapshotFilenames.contains(filename) { response.snapshotFilenames.append(filename) }
        try save()
    }
}

@MainActor
enum FreoDiagnosticRunner {
    private static var started = false
    static func runOnce(arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard !started else { return }; started = true
        let id: String
        do { guard let value = try FreoDiagnosticRequest.invocationID(arguments: arguments) else { return }; id = value }
        catch { return }
        let files: FreoDiagnosticFiles
        do { files = try FreoDiagnosticFiles() } catch { return }
        let context = FreoDiagnosticContext(files: files, id: id)
        let data: Data
        do { data = try files.claimAndRead(id: id) }
        catch FreoDiagnosticFailure.alreadyClaimed { return }
        catch { context.response.state = "failed"; context.response.error = sanitized(error); try? context.save(); return }
        do {
            try context.save()
            let request = try FreoDiagnosticRequest.decode(data, expectedID: id)
            context.response.operation = request.operation; context.response.state = "running"
            try context.progress("Restoring the app’s saved session…")
            let service = NarwalService()
            guard let devices = try await service.restoreSession() else { throw FreoDiagnosticFailure.noSavedSession }
            let supported = devices.filter { $0.productKey == "EHf6cRNRGT" && $0.canControl }
            guard supported.count == 1, let device = supported.first else { throw FreoDiagnosticFailure.ambiguousRobot }
            switch request.operation {
            case "inspect":
                context.response.deviceDigest = deviceDigest(device)
                try context.save()
                try await inspect(service: service, device: device, context: context)
            case "partition":
                guard let partition = request.partition else { throw FreoDiagnosticFailure.invalidRequest }
                try await partitionMap(partition, service: service, device: device, context: context)
            default: throw FreoDiagnosticFailure.invalidRequest
            }
            context.response.state = "completed"; context.response.progress = nil; try context.save()
        } catch {
            context.response.state = "failed"; context.response.error = sanitized(error)
            if let stopped = error as? RoomPartitionTransactionError {
                context.response.completedSteps = stopped.completedSteps; context.response.mayHaveChanged = stopped.mayHaveChanged
            }
            try? context.save()
        }
    }

    static func inspect(service: NarwalService, device: RobotDevice, context: FreoDiagnosticContext) async throws {
        let status = try await service.status(device: device)
        context.response.status = .init(status); try context.progress("Reading the current editable map…")
        let current = try await service.mapSnapshot(device: device)
        let editable = try await service.editableMapSnapshot(device: device, mapID: current.mapID)
        let saved = try MapSnapshotStore.preserveReadback(editable)
        try context.record(editable, filename: saved.lastPathComponent)
        let task = try await service.plan(device: device)
        context.response.currentTask = .init(task); try context.save()
    }

    nonisolated static func requireStandby(_ status: RobotStatus) throws {
        guard status.workingCode == 1, status.isPaused != true else { throw FreoDiagnosticFailure.notStandby }
    }
    /// Canonical binding for explicit request files: lowercase SHA256 hex of
    /// UTF-8 productKey + ":" + deviceID, with the discovered ID's exact casing.
    /// Both identifiers have validated alphanumeric formats; neither contains ":".
    nonisolated static func deviceDigest(_ device: RobotDevice) -> String {
        SHA256.hash(data: Data((device.productKey + ":" + device.id).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func validateDevice(_ request: FreoDiagnosticRequest.Partition,
                                          device: RobotDevice) throws {
        guard request.expectedDeviceDigest == deviceDigest(device) else {
            throw FreoDiagnosticFailure.deviceMismatch
        }
    }
    static func validate(_ request: FreoDiagnosticRequest.Partition, baseline: MapSnapshot) throws -> RoomPartitionPlan {
        try validateDevice(request, device: RobotDevice(id: baseline.deviceID,
            productKey: baseline.productKey, name: ""))
        guard baseline.mapID == request.mapID, baseline.mapVersion == request.mapVersion,
              baseline.editVersion == request.editVersion,
              request.sources.allSatisfy({ source in baseline.floorplan.rooms.first(where: { $0.id == source.id })?.name == source.name }) else {
            throw FreoDiagnosticFailure.baselineMismatch
        }
        let selected = Set(request.sources.map(\.id))
        let plan = try request.usesDrawnBox == true
            ? RoomPartitionPlanner.makeBox(floorplan: baseline.floorplan, sourceRoomIDs: selected,
                                           rectangle: request.rectangle.grid)
            : RoomPartitionPlanner.make(floorplan: baseline.floorplan, sourceRoomIDs: selected,
                                        rectangle: request.rectangle.grid)
        guard try RoomPartitionTransaction.remainingStage(plan: plan, floorplan: baseline.floorplan).rawValue == request.expectedRemainingStage else {
            throw FreoDiagnosticFailure.baselineMismatch
        }
        return plan
    }
    static func partitionMap(_ request: FreoDiagnosticRequest.Partition, service: NarwalService,
                             device: RobotDevice, context: FreoDiagnosticContext) async throws {
        // Check identity immediately after restoration, before status/map reads
        // or any operation. A fresh matching map is still required below.
        try validateDevice(request, device: device)
        let status = try await service.status(device: device)
        context.response.status = .init(status); try context.save(); try requireStandby(status)
        let baseline = try await service.editableMapSnapshot(device: device, mapID: request.mapID)
        let plan = try validate(request, baseline: baseline)
        context.response.remainingStage = request.expectedRemainingStage
        let preserved = try MapSnapshotStore.preserve(baseline)
        try context.record(baseline, filename: preserved.lastPathComponent)
        do {
            let result = try await RoomPartitionTransaction.commit(plan: plan, baseline: baseline,
                kitchenName: request.targetName, hallwayName: request.remainderName,
                resumeOnly: request.expectedRemainingStage != RoomPartitionRemainingStage.wholeArea.rawValue,
                read: { try await service.editableMapSnapshot(device: device, mapID: request.mapID) },
                apply: { snapshot, operations in
                    let currentStatus = try await service.status(device: device)
                    try requireStandby(currentStatus)
                    try await context.markAttempt(currentStatus)
                    let result = try await service.applyRoomOperations(device: device, baseline: snapshot, operations: operations)
                    try await context.record(result.snapshot, filename: result.preservedSnapshotURL.lastPathComponent)
                    return result
                }, progress: { text in try? await context.progress(text) })
            try context.record(result)
        } catch {
            // One read preserves the actual state after a stopped transaction.
            // It never retries an operation or resumes a later divider stage.
            do {
                let latest = try await service.editableMapSnapshot(device: device, mapID: request.mapID)
                let saved = try MapSnapshotStore.preserveReadback(latest)
                try context.record(latest, filename: saved.lastPathComponent)
            } catch { context.response.recoveryReadbackUnavailable = true }
            throw error
        }
    }
    static func sanitized(_ error: Error) -> String {
        if let failure = error as? FreoDiagnosticFailure { return failure.message }
        if error is CancellationError { return "The diagnostic task was cancelled. It will not be retried." }
        if let stopped = error as? RoomPartitionTransactionError { return sanitizedText(stopped.errorDescription ?? "The map edit stopped.") }
        if let failure = error as? MapEditError { return sanitizedText(failure.errorDescription ?? "The map edit could not be verified.") }
        if let failure = error as? ConnectorError { return sanitizedText(failure.errorDescription ?? "The request failed.") }
        if error is SessionRestoreFailure || error is SessionStorageFailure || error is AccountHTTPError {
            return "The saved account session could not be restored or renewed. Open Connection to review it."
        }
        return "The diagnostic request failed. No automatic retry was made."
    }
    private static func sanitizedText(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(String.init).joined().prefix(1200))
    }
}
#endif
