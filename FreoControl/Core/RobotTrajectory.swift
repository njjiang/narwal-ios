import Foundation

/// Coordinates are raster cell edges, top-left origin, y increasing downward.
/// They are grid units, not meters. A route is telemetry, not proof of coverage.
public struct RobotPathPoint: Equatable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct RobotPathSegment: Identifiable, Equatable, Codable, Sendable {
    /// The first point index in the complete received trajectory.
    public let id: Int
    /// Official type: 0 unknown, 1 navigation, 2 margin, 3 obstacle margin,
    /// 4 clean, 5 carpet exploration, 6 recoverage, 7 pet search.
    public let typeCode: Int
    public let points: [RobotPathPoint]
    public init(id: Int, typeCode: Int, points: [RobotPathPoint]) {
        self.id = id; self.typeCode = typeCode; self.points = points
    }
}

public struct RobotPose: Equatable, Codable, Sendable {
    public let point: RobotPathPoint
    public init(point: RobotPathPoint) { self.point = point }
}

public struct RobotTrajectory: Equatable, Codable, Sendable {
    public let productKey: String
    public let deviceID: String
    public let mapID: Int
    public let mapVersion: UInt32?
    public let editVersion: UInt32?
    public let points: [RobotPathPoint]
    public let segments: [RobotPathSegment]
    public let pose: RobotPose?
    public let capturedAt: Date
    /// Pose freshness, not a cleaning start time or a per-point timestamp.
    public let deviceTimestampMilliseconds: UInt64?
    /// A response sequence, not a stable cleaning identifier.
    public let sequenceID: UInt64?
    public let unavailableReason: String?
    public let isSimulated: Bool

    public init(productKey: String, deviceID: String, mapID: Int, mapVersion: UInt32?,
                editVersion: UInt32?, points: [RobotPathPoint], segments: [RobotPathSegment],
                pose: RobotPose?, capturedAt: Date, deviceTimestampMilliseconds: UInt64?,
                sequenceID: UInt64?, unavailableReason: String? = nil, isSimulated: Bool = false) {
        self.productKey = productKey; self.deviceID = deviceID; self.mapID = mapID
        self.mapVersion = mapVersion; self.editVersion = editVersion
        self.points = points; self.segments = segments; self.pose = pose; self.capturedAt = capturedAt
        self.deviceTimestampMilliseconds = deviceTimestampMilliseconds; self.sequenceID = sequenceID
        self.unavailableReason = unavailableReason; self.isSimulated = isSimulated
    }
}

public struct LiveMapSnapshot: Sendable {
    public let snapshot: MapSnapshot
    public let trajectory: RobotTrajectory
    public init(snapshot: MapSnapshot, trajectory: RobotTrajectory) {
        self.snapshot = snapshot; self.trajectory = trajectory
    }
}

extension NarwalCodec {
    /// Official StaticMapPayload / RobotTrajectory / RobotTrajectoryInfo schema,
    /// recovered from the Narwal Android 2.10.90 app. No account data is decoded.
    /// A malformed known field fails the observation; unknown formats/arcs are
    /// explicitly unavailable rather than invented as straight cleaning lines.
    public static func trajectory(snapshot: MapSnapshot) throws -> RobotTrajectory {
        try decodeTrajectory(mapPayload: snapshot.staticMapPayload, floorplan: snapshot.floorplan,
            device: RobotDevice(id: snapshot.deviceID, productKey: snapshot.productKey, name: ""),
            capturedAt: snapshot.capturedAt, mapVersion: snapshot.mapVersion, editVersion: snapshot.editVersion)
    }

    /// Read-only archived maps may omit revisions. Never turn those maps into
    /// editable snapshots, invent version zero, or attach the current live map.
    static func archivedTrajectory(mapPayload: Data, floorplan: Floorplan, device: RobotDevice,
                                   capturedAt: Date, mapVersion: UInt32?) throws -> RobotTrajectory {
        try decodeTrajectory(mapPayload: mapPayload, floorplan: floorplan, device: device,
                             capturedAt: capturedAt, mapVersion: mapVersion, editVersion: nil)
    }

    private static func decodeTrajectory(mapPayload: Data, floorplan: Floorplan, device: RobotDevice,
                                         capturedAt: Date, mapVersion: UInt32?, editVersion: UInt32?) throws -> RobotTrajectory {
        let entries = try fields(mapPayload, limit: 1024 * 1024, countLimit: 4096)
        func unsigned(_ tag: Int) throws -> UInt64? {
            guard let value = try one(entries, tag) else { return nil }
            guard value.wire == 0, let integer = value.integer else { throw pathError("Invalid route freshness metadata.") }
            return integer
        }
        let sequence = try unsigned(22), timestamp = try unsigned(36)
        // Timestamp is uint64 in the protocol. Keep its complete value; archive
        // freshness checks reject implausible values without overflowing Int.
        let format = try scalar(one(entries, 15), maximum: UInt64(UInt32.max)) ?? 0
        let direct = try message(one(entries, 13)), encoded = try message(one(entries, 14))
        let poseData = try message(one(entries, 24))
        let arcs = entries.filter { $0.tag == 43 }
        for arc in arcs { _ = try message(arc, required: true) }
        func result(_ points: [RobotPathPoint] = [], _ segments: [RobotPathSegment] = [],
                    pose: RobotPose? = nil, reason: String? = nil) -> RobotTrajectory {
            RobotTrajectory(productKey: device.productKey, deviceID: device.id,
                mapID: floorplan.mapID, mapVersion: mapVersion, editVersion: editVersion,
                points: points, segments: segments, pose: pose, capturedAt: capturedAt,
                deviceTimestampMilliseconds: timestamp, sequenceID: sequence, unavailableReason: reason)
        }
        // Use the same proven half-cell transform as saved map geometry. This
        // validates border spans, zero rotation, identity, and raster size.
        let coordinates: MapEditCoordinates
        do { coordinates = try MapEditCoordinates(floorplan: floorplan, productKey: device.productKey, staticMapPayload: mapPayload) }
        catch { return result(reason: "Route coordinates are not supported for this map.") }
        let origin = try coordinates.point(RoomGridPoint(x: 0, y: 0))
        func display(_ x: Double, _ y: Double) throws -> RobotPathPoint {
            guard x.isFinite, y.isFinite, abs(x) <= 8_000_000, abs(y) <= 8_000_000 else {
                throw pathError("Invalid robot route coordinates.")
            }
            let point = RobotPathPoint(x: x - Double(origin.x), y: Double(origin.y) - y)
            // Do not clamp or connect out-of-map telemetry to a plausible cell.
            guard point.x >= 0, point.y >= 0,
                  point.x <= Double(floorplan.width), point.y <= Double(floorplan.height) else {
                throw pathError("Robot route coordinates fall outside the received map.")
            }
            return point
        }
        var pose: RobotPose?
        if let poseData {
            let poseFields = try fields(poseData, limit: 1024, countLimit: 32)
            if let location = try message(one(poseFields, 1)) {
                let locationFields = try fields(location, limit: 256, countLimit: 16)
                // A present Point uses protobuf float defaults for zero axes.
                let x = try pathFloat(one(locationFields, 1)), y = try pathFloat(one(locationFields, 2))
                pose = RobotPose(point: try display(x, y))
            }
        }
        guard arcs.isEmpty else {
            return result(pose: pose, reason: "This route contains curves that are not supported yet.")
        }
        let data: Data
        switch format {
        case 1:
            guard let direct else { return result(pose: pose, reason: "No route was returned by the robot.") }
            guard encoded?.isEmpty != false else { throw pathError("Conflicting robot route representations.") }
            data = direct
        case 2:
            // Official decompressData 0x1fcd33c–0x1fcd354 calls
            // RobotTrajectory.fromBuffer on field14 for PROTOBUF_STRING.
            guard let encoded else { throw pathError("The encoded robot route is missing.") }
            guard direct?.isEmpty != false else { throw pathError("Conflicting robot route representations.") }
            data = encoded
        case 0 where direct == nil && encoded == nil:
            return result(pose: pose, reason: "No route was returned by the robot.")
        default:
            // Format3 is named COMPRESSED_ON_GZIP, but this app's route branch
            // does not prove its decoded representation. Do not inflate guesses.
            return result(pose: pose, reason: "The robot returned an unsupported route format (\(format)).")
        }
        let pathFields = try fields(data, limit: 1024 * 1024, countLimit: 200_016)
        let xs = try pathFloats(pathFields.filter { $0.tag == 1 }), ys = try pathFloats(pathFields.filter { $0.tag == 2 })
        guard xs.count == ys.count else { throw pathError("Robot route coordinate counts do not match.") }
        let points = try zip(xs, ys).map(display)
        let infos = entries.filter { $0.tag == 31 }
        guard infos.count <= 2048 else { throw pathError("The robot route has too many state changes.") }
        var transitions: [(index: Int, type: Int)] = []
        for info in infos {
            let values = try fields(message(info, required: true)!, limit: 256, countLimit: 16)
            let index = try scalar(one(values, 2), maximum: 100_000) ?? 0
            let type = try scalar(one(values, 1), maximum: UInt64(Int32.max)) ?? 0
            guard index < points.count, transitions.last.map({ index > $0.index }) ?? true else {
                throw pathError("Robot route state indices are duplicate, unordered, or outside the route.")
            }
            transitions.append((index, type))
        }
        if !points.isEmpty && transitions.first?.index != 0 { transitions.insert((0, 0), at: 0) }
        var segments: [RobotPathSegment] = []
        for (offset, transition) in transitions.enumerated() {
            let end = offset + 1 < transitions.count ? transitions[offset + 1].index : points.count - 1
            // An index begins the following segment. The transition point is
            // also the endpoint of the preceding segment (official 0x1107e70).
            if end > transition.index {
                segments.append(RobotPathSegment(id: transition.index, typeCode: transition.type,
                    points: Array(points[transition.index...end])))
            }
        }
        return result(points, segments, pose: pose)
    }

    static func pathFloat(_ field: Field?) throws -> Double {
        guard let field else { return 0 }
        guard field.wire == 5, let bytes = field.bytes, bytes.count == 4 else {
            throw pathError("Invalid robot pose coordinate.")
        }
        return try float32(bytes)
    }
    static func pathFloats(_ fields: [Field]) throws -> [Double] {
        var result: [Double] = []
        for field in fields {
            guard let bytes = field.bytes, field.wire == 2 || field.wire == 5,
                  bytes.count % 4 == 0, field.wire != 5 || bytes.count == 4,
                  bytes.count / 4 <= 100_000 - result.count else {
                throw pathError("Invalid or oversized robot route.")
            }
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                result.append(try float32(bytes.subdata(in: offset..<offset + 4)))
            }
        }
        return result
    }
    private static func float32(_ bytes: Data) throws -> Double {
        let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        let value = Double(Float(bitPattern: bits))
        guard value.isFinite else { throw pathError("The robot route contains a non-finite coordinate.") }
        return value
    }
    private static func pathError(_ text: String) -> ConnectorError { .invalid(text) }
}
