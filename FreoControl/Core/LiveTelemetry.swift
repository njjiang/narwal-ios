import Foundation

public enum LiveMapConnectionState: Equatable, Sendable {
    case inactive, connecting, waiting, live, polling
}

/// Activation confirms a reporting lease, not movement. Trajectories contain
/// received observations only; a sequence gap requires a fresh map snapshot.
public enum LiveTelemetryEvent: Sendable {
    case activated(leaseMilliseconds: Int, intervalMilliseconds: Int)
    case trajectory(RobotTrajectory)
    case resyncRequired(reason: String)
}

/// One baseline, one device, one bounded subscription window. DisplayMap does
/// not carry a map ID. Its clean-map sequence must connect to StaticMapPayload
/// field22 before a pose or path can be attached to that baseline.
public struct LiveTelemetryAccumulator: Sendable {
    private let snapshot: MapSnapshot
    private let origin: MapEditPoint
    private var sequence: UInt64?
    private var points: [RobotPathPoint]
    private var types: [Int: Int]
    private var timestamp: UInt64?
    private var stopped = false
    private var routeReason: String?

    public init(baseline: LiveMapSnapshot) throws {
        snapshot = baseline.snapshot
        guard baseline.trajectory.productKey == snapshot.productKey,
              baseline.trajectory.deviceID == snapshot.deviceID,
              baseline.trajectory.mapID == snapshot.mapID,
              baseline.trajectory.mapVersion == snapshot.mapVersion,
              baseline.trajectory.editVersion == snapshot.editVersion,
              !baseline.trajectory.isSimulated else {
            throw ConnectorError.invalid("The live map baseline does not match the selected map.")
        }
        let decoded = try NarwalCodec.trajectory(snapshot: snapshot)
        let coordinates = try MapEditCoordinates(snapshot: snapshot)
        origin = try coordinates.point(RoomGridPoint(x: 0, y: 0))
        sequence = decoded.sequenceID; points = decoded.points
        timestamp = decoded.deviceTimestampMilliseconds; routeReason = decoded.unavailableReason
        types = [:]
        if !points.isEmpty {
            let fields = try NarwalCodec.fields(snapshot.staticMapPayload, limit: 1_048_576, countLimit: 4096)
            for info in fields.filter({ $0.tag == 31 }) {
                let value = try Self.routeInfo(info)
                types[value.index] = value.type
            }
            if types[0] == nil { types[0] = 0 }
        }
    }

    /// Payload is a raw DisplayMap protobuf, as delivered by the official
    /// general-topic demultiplexer. It is not a command-response envelope.
    public mutating func consume(_ payload: Data, receivedAt: Date = Date()) throws -> LiveTelemetryEvent? {
        guard !stopped else { return nil }
        let values = try NarwalCodec.fields(payload, limit: 1_048_576, countLimit: 4096)
        // Validate singleton occurrences even when the map is unsupported.
        for tag in [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 13] { _ = try NarwalCodec.one(values, tag) }
        guard try NarwalCodec.scalar(NarwalCodec.one(values, 6)) == 2 else {
            return resync("The robot is reporting a different map type.")
        }
        guard try NarwalCodec.message(NarwalCodec.one(values, 8)) == nil else {
            return resync("The robot reported a complete map change.")
        }
        guard let sequence, sequence < UInt64(UInt32.max),
              let incremental = try NarwalCodec.message(NarwalCodec.one(values, 7)) else {
            return resync("A fresh map sequence is needed for live tracking.")
        }
        let delta = try NarwalCodec.fields(incremental, limit: 1_048_576, countLimit: 4096)
        guard let first = try NarwalCodec.scalar(NarwalCodec.one(delta, 1), maximum: UInt64(UInt32.max)),
              let current = try NarwalCodec.scalar(NarwalCodec.one(delta, 2), maximum: UInt64(UInt32.max)),
              first <= current else {
            throw ConnectorError.invalid("Invalid live map sequence.")
        }
        if UInt64(current) <= sequence { return nil } // duplicate or out-of-order delivery
        guard UInt64(first) <= sequence + 1 else { return resync("Live map updates were missed. Refreshing the map.") }
        // Raster changes are deliberately not applied to the saved floorplan.
        // The sequence gates observed pose/path only; next window re-reads map.
        _ = try NarwalCodec.message(NarwalCodec.one(delta, 3))
        let incomingTimestamp: UInt64?
        if let value = try NarwalCodec.one(values, 10) {
            guard value.wire == 0, let integer = value.integer else { throw ConnectorError.invalid("Invalid live pose timestamp.") }
            incomingTimestamp = integer
        } else { incomingTimestamp = nil }
        if let incomingTimestamp, let timestamp, incomingTimestamp < timestamp {
            return resync("The live pose timestamp moved backwards.")
        }

        var nextPoints = points, nextTypes = types, nextReason = routeReason
        let arcs = values.filter { $0.tag == 15 }
        for arc in arcs { _ = try NarwalCodec.message(arc, required: true) }
        if !arcs.isEmpty {
            nextPoints = []; nextTypes = [:]
            nextReason = "This live route contains curves that are not supported yet."
        } else if let path = try NarwalCodec.message(NarwalCodec.one(values, 2)) {
            let pathFields = try NarwalCodec.fields(path, limit: 1_048_576, countLimit: 200_016)
            let xs = try NarwalCodec.pathFloats(pathFields.filter { $0.tag == 1 })
            let ys = try NarwalCodec.pathFloats(pathFields.filter { $0.tag == 2 })
            guard xs.count == ys.count else { throw ConnectorError.invalid("Live route coordinate counts do not match.") }
            let additions = try zip(xs, ys).map { try display($0.0, $0.1) }
            let start = try NarwalCodec.scalar(NarwalCodec.one(values, 3), maximum: 100_000) ?? 0
            guard start <= nextPoints.count, additions.count <= 100_000 - start else {
                return resync("The live route has a missing section.")
            }
            let overlap = min(additions.count, nextPoints.count - start)
            guard zip(nextPoints[start..<(start + overlap)], additions.prefix(overlap)).allSatisfy({ $0 == $1 }) else {
                return resync("The live route no longer matches the current cleaning path.")
            }
            nextPoints.append(contentsOf: additions.dropFirst(overlap))
            if !additions.isEmpty { nextReason = nil }
            let infos = values.filter { $0.tag == 9 }
            guard infos.count <= 2048 else { throw ConnectorError.invalid("Too many live route state changes.") }
            var receivedIndices = Set<Int>()
            for info in infos {
                let value = try Self.routeInfo(info)
                guard value.index < nextPoints.count, receivedIndices.insert(value.index).inserted else {
                    throw ConnectorError.invalid("Invalid live route state index.")
                }
                // The official app keys trajectoryInfos by the absolute index.
                // A later report may add a type for previously unknown points.
                nextTypes[value.index] = value.type
            }
            if !nextPoints.isEmpty && nextTypes[0] == nil { nextTypes[0] = 0 }
            guard nextTypes.count <= 2048 else { return resync("The live route needs a fresh snapshot.") }
        }
        var pose: RobotPose?
        if let position = try NarwalCodec.message(NarwalCodec.one(values, 1)) {
            let positionFields = try NarwalCodec.fields(position, limit: 1024, countLimit: 32)
            if let location = try NarwalCodec.message(NarwalCodec.one(positionFields, 1)) {
                let fields = try NarwalCodec.fields(location, limit: 256, countLimit: 16)
                pose = try RobotPose(point: display(NarwalCodec.pathFloat(NarwalCodec.one(fields, 1)),
                                                   NarwalCodec.pathFloat(NarwalCodec.one(fields, 2))))
            }
        }
        // Do not carry a stale pose forward with a new reception timestamp.
        self.sequence = UInt64(current); points = nextPoints; types = nextTypes
        timestamp = incomingTimestamp ?? timestamp; routeReason = nextReason
        let ordered = nextTypes.sorted { $0.key < $1.key }
        var segments: [RobotPathSegment] = []
        for (offset, value) in ordered.enumerated() {
            let end = offset + 1 < ordered.count ? ordered[offset + 1].key : nextPoints.count - 1
            if value.key < end {
                segments.append(RobotPathSegment(id: value.key, typeCode: value.value,
                    points: Array(nextPoints[value.key...end])))
            }
        }
        return .trajectory(RobotTrajectory(productKey: snapshot.productKey, deviceID: snapshot.deviceID,
            mapID: snapshot.mapID, mapVersion: snapshot.mapVersion, editVersion: snapshot.editVersion,
            points: nextPoints, segments: segments, pose: pose, capturedAt: receivedAt,
            deviceTimestampMilliseconds: pose == nil ? nil : incomingTimestamp,
            sequenceID: UInt64(current), unavailableReason: nextReason))
    }

    private mutating func resync(_ reason: String) -> LiveTelemetryEvent {
        stopped = true
        return .resyncRequired(reason: reason)
    }
    private func display(_ x: Double, _ y: Double) throws -> RobotPathPoint {
        let point = RobotPathPoint(x: x - Double(origin.x), y: Double(origin.y) - y)
        guard x.isFinite, y.isFinite, abs(x) <= 8_000_000, abs(y) <= 8_000_000,
              point.x >= 0, point.y >= 0, point.x <= Double(snapshot.floorplan.width),
              point.y <= Double(snapshot.floorplan.height) else {
            throw ConnectorError.invalid("Live robot coordinates fall outside the current map.")
        }
        return point
    }
    private static func routeInfo(_ field: NarwalCodec.Field) throws -> (index: Int, type: Int) {
        let values = try NarwalCodec.fields(NarwalCodec.message(field, required: true)!, limit: 256, countLimit: 16)
        return (try NarwalCodec.scalar(NarwalCodec.one(values, 2), maximum: 100_000) ?? 0,
                try NarwalCodec.scalar(NarwalCodec.one(values, 1), maximum: UInt64(Int32.max)) ?? 0)
    }
}

extension NarwalCodec {
    /// Official activation requests a finite display-map reporting lease. No
    /// sensor, debug, cleaning, mapping or persistent configuration is enabled.
    static func liveActivation(uuid: String) throws -> Data {
        try identity(uuid: uuid) + encodeBytes(1, encodeNumber(2, 2_000)) + encodeNumber(2, 60_000) + encodeNumber(3, 0)
    }
    static func liveActivationReply(_ payload: Data) throws -> (lease: Int, interval: Int) {
        let values = try fields(unwrap(payload), countLimit: 32)
        let durations = try fields(message(one(values, 1), required: true)!, limit: 1024, countLimit: 32)
        guard (try scalar(one(values, 4), maximum: UInt64(UInt32.max)) ?? 0) == 0,
              let lease = try scalar(one(values, 2), maximum: 60_000, positive: true),
              let interval = try scalar(one(durations, 2), maximum: 60_000, positive: true) else {
            throw ConnectorError.invalid("The robot did not accept live map reporting.")
        }
        return (lease, interval)
    }
    static func generalDisplayMap(_ payload: Data) throws -> Data? {
        let values = try fields(payload, limit: 1_048_576, countLimit: 32)
        guard let url = try message(one(values, 1)), url == Data("/map/display_map".utf8) else { return nil }
        return try message(one(values, 2), required: true)
    }
}
