import Foundation

/// Checks the room-adjacency records changed by one reviewed map operation.
/// Android 2.10.90 Door.BuilderInfo (0x1975520): field 1 packed uint32
/// roomIds, 2 repeated integer points, 3 sill flag, 4 height, 5 type,
/// 6 color, 7 float theta. Official extraction: save-Door.dart.
/// The observed X Ultra merge removed only the internal adjacency and remapped
/// an external adjacency's IDs; every surviving non-ID byte was unchanged.
/// This does not relax raster, room-record, or other map-metadata validation.
public enum RoomDoorReadback {
    public static func validate(baseline: MapSnapshot, current: MapSnapshot,
                                operations: [RoomMapOperation], allowsGridRounding: Bool = false, roomIDMapping: [Int: Int] = [:]) throws {
        guard baseline.productKey == current.productKey, baseline.deviceID == current.deviceID,
              baseline.mapID == current.mapID, !operations.isEmpty, operations.count <= 64 else {
            throw invalid("Door verification requires the same robot, map and reviewed operation.")
        }
        let oldIDs = Set(baseline.floorplan.rooms.map(\.id))
        let newIDs = Set(current.floorplan.rooms.map(\.id))
        let before = try doors(baseline.staticMapPayload, roomIDs: oldIDs)
        let after = try doors(current.staticMapPayload, roomIDs: newIDs)
        if operations.allSatisfy({ if case .rename = $0 { return true }; return false }) {
            guard operations.allSatisfy({
                if case .rename(let id, _) = $0 { return oldIDs.contains(id) && newIDs.contains(id) }
                return false
            }), multiset(before.map(\.raw)) == multiset(after.map(\.raw)) else {
                throw invalid("Renaming changed a room adjacency. Further edits stopped.")
            }
            return
        }
        guard operations.count == 1 else {
            throw invalid("Verify each room merge or split separately.")
        }
        switch operations[0] {
        case .merge(let first, let second, _):
            let untouched = Set(oldIDs.subtracting([first, second]).map { roomIDMapping[$0] ?? $0 })
            let returned = newIDs.subtracting(untouched)
            guard first != second, oldIDs.contains(first), oldIDs.contains(second),
                  untouched.isSubset(of: newIDs), returned.count == 1, let result = returned.first else {
                throw invalid("The merge returned unexpected room identifiers.")
            }
            var remaining = after
            var verifiedPlainPairs = Set<Set<Int>>()
            for door in before {
                let ids = Set(door.ids.map {
                    $0 == first || $0 == second ? result : roomIDMapping[$0] ?? $0
                })
                if ids.count < 2 {
                    guard door.onlyGeometry else {
                        throw invalid("The removed internal adjacency contains additional door settings.")
                    }
                    continue
                }
                let affected = door.ids.contains(first) || door.ids.contains(second)
                if allowsGridRounding && affected && door.onlyGeometry {
                    if verifiedPlainPairs.contains(ids) { continue }
                    let oldSegments = before.filter { old in
                        old.onlyGeometry && (old.ids.contains(first) || old.ids.contains(second)) &&
                            Set(old.ids.map { $0 == first || $0 == second ? result : roomIDMapping[$0] ?? $0 }) == ids
                    }
                    let candidates = remaining.indices.filter { remaining[$0].ids == ids }
                    guard !candidates.isEmpty,
                          sameCoverage(oldSegments, candidates.map { remaining[$0] }, allowsCoalescingEnvelope: true) else {
                        throw invalid("The merge changed an external adjacency beyond grid rounding.")
                    }
                    for index in candidates.sorted(by: >) { remaining.remove(at: index) }
                    verifiedPlainPairs.insert(ids)
                    continue
                }
                let candidates = remaining.indices.filter { index in
                    let candidate = remaining[index]
                    return candidate.ids == ids &&
                        (candidate.nonIDs == door.nonIDs ||
                         (allowsGridRounding && affected && candidate.onlyGeometry && door.onlyGeometry &&
                          roundedPointsMatch(candidate.points, door.points)))
                }
                guard candidates.count == 1, let index = candidates.first else {
                    throw invalid("The merge changed an unrelated door or its geometry. Further edits stopped.")
                }
                remaining.remove(at: index)
            }
            guard remaining.isEmpty else {
                throw invalid("The merge added an unexpected adjacency.")
            }
        case .split(let start, let end, let left, let requestedRight):
            let untouched = Set(oldIDs.subtracting([left]).map { roomIDMapping[$0] ?? $0 })
            let children = newIDs.subtracting(untouched)
            guard left != requestedRight, oldIDs.contains(left), !oldIDs.contains(requestedRight),
                  untouched.isSubset(of: newIDs), children.count == 2,
                  valid(start), valid(end), start != end else {
                throw invalid("The split returned unexpected room identifiers or coordinates.")
            }
            var remaining = after
            var verifiedNeighbors = Set<Set<Int>>()
            for old in before {
                if allowsGridRounding && old.onlyGeometry && old.ids.contains(left) {
                    let others = Set(old.ids.subtracting([left]).map { roomIDMapping[$0] ?? $0 })
                    if verifiedNeighbors.contains(others) { continue }
                    let oldSegments = before.filter {
                        $0.onlyGeometry && $0.ids.contains(left) &&
                            Set($0.ids.subtracting([left]).map { roomIDMapping[$0] ?? $0 }) == others
                    }
                    let candidates = remaining.indices.filter { index in
                        children.contains { remaining[index].ids == others.union([$0]) }
                    }
                    guard !candidates.isEmpty, candidates.count <= children.count,
                          (sameCoverage(oldSegments, candidates.map { remaining[$0] }) ||
                           regeneratedSplitAdjacencies(candidates.map { remaining[$0] },
                                                      before: baseline, after: current)) else {
                        throw invalid("The split changed an external adjacency beyond grid rounding.")
                    }
                    for index in candidates.sorted(by: >) { remaining.remove(at: index) }
                    verifiedNeighbors.insert(others)
                    continue
                }
                let candidates = remaining.indices.filter { index in
                    let candidate = remaining[index]
                    if !old.ids.contains(left) {
                        return candidate.ids == Set(old.ids.map { roomIDMapping[$0] ?? $0 }) &&
                            candidate.nonIDs == old.nonIDs
                    }
                    let matchesGeometry = candidate.nonIDs == old.nonIDs ||
                        (allowsGridRounding && candidate.onlyGeometry && old.onlyGeometry &&
                         roundedPointsMatch(candidate.points, old.points))
                    guard matchesGeometry else { return false }
                    let others = Set(old.ids.subtracting([left]).map { roomIDMapping[$0] ?? $0 })
                    return children.contains { candidate.ids == others.union([$0]) }
                }
                guard candidates.count == 1, let index = candidates.first else {
                    throw invalid("The split changed or lost an existing door. Further edits stopped.")
                }
                remaining.remove(at: index)
            }
            for added in remaining {
                guard added.ids == children, added.onlyGeometry,
                      added.points.allSatisfy({ onSegment($0, start: start, end: end, tolerance: allowsGridRounding ? 0.5 : 0) }) else {
                    // The box editor permits the observed half-cell integer
                    // rounding. Other callers retain exact verification.
                    throw invalid("The new internal door does not exactly match the reviewed divider. Its rounding is not verified.")
                }
            }
        case .rename:
            throw invalid("Unsupported combined room operation.")
        }
    }

    private struct Point: Hashable { let x: Int; let y: Int }
    private struct Door {
        let ids: Set<Int>, points: [Point], nonIDs: Data, raw: Data, onlyGeometry: Bool
    }
    private struct Field {
        let tag: Int, wire: Int, number: UInt64?, bytes: Data?, raw: Data
    }
    private static func invalid(_ message: String) -> ConnectorError { .invalid(message) }
    private static func valid(_ point: MapEditPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000
    }
    /// Splitting can subdivide a shared boundary; merging can coalesce its
    /// segments. Its endpoint envelope stays within one native grid cell.
    private static func sameCoverage(_ before: [Door], _ after: [Door],
                                     allowsCoalescingEnvelope: Bool = false) -> Bool {
        guard !before.isEmpty, !after.isEmpty, after.count <= max(2, before.count),
              before.allSatisfy(\.onlyGeometry), after.allSatisfy(\.onlyGeometry) else { return false }
        let old = before.flatMap(\.points), new = after.flatMap(\.points)
        guard let oldMinX = old.map(\.x).min(), let oldMaxX = old.map(\.x).max(),
              let oldMinY = old.map(\.y).min(), let oldMaxY = old.map(\.y).max(),
              let newMinX = new.map(\.x).min(), let newMaxX = new.map(\.x).max(),
              let newMinY = new.map(\.y).min(), let newMaxY = new.map(\.y).max() else { return false }
        // A native two-point adjacency can summarize several sides of a
        // concave room. Coalescing keeps endpoints inside the old envelope.
        if allowsCoalescingEnvelope && after.count < before.count {
            return newMinX >= oldMinX - 1 && newMaxX <= oldMaxX + 1 &&
                newMinY >= oldMinY - 1 && newMaxY <= oldMaxY + 1
        }
        return abs(oldMinX - newMinX) <= 1 && abs(oldMaxX - newMaxX) <= 1 &&
            abs(oldMinY - newMinY) <= 1 && abs(oldMaxY - newMaxY) <= 1
    }

    /// The X Ultra regenerates plain adjacency summaries after a split. Their
    /// endpoints may extend beyond the old summary (which can omit contact
    /// beside a third room). Accept this only when the saved raster independently
    /// proves each returned pair touches, and all endpoints remain inside both
    /// rooms' overlapping bounds. Door settings and unrelated records stay exact.
    private static func regeneratedSplitAdjacencies(_ doors: [Door],
                                                    before: MapSnapshot, after: MapSnapshot) -> Bool {
        guard !doors.isEmpty, doors.allSatisfy({ $0.onlyGeometry && $0.ids.count == 2 && $0.points.count == 2 }),
              before.floorplan.width == after.floorplan.width,
              before.floorplan.height == after.floorplan.height,
              let coordinates = try? MapEditCoordinates(snapshot: after),
              let origin = try? coordinates.point(.init(x: 0, y: 0)) else { return false }
        let map = after.floorplan
        guard map.width > 0, map.height > 0, map.width <= 1_000_000 / map.height,
              map.pixels.count == map.width * map.height else { return false }
        for door in doors {
            let ids = door.ids.sorted()
            var bounds: [Int: (minX: Int, minY: Int, maxX: Int, maxY: Int)] = [:]
            var touches = false
            for (index, raw) in map.pixels.enumerated() {
                let id = MapPixel(rawValue: raw).roomID
                guard door.ids.contains(id) else { continue }
                let x = index % map.width, y = map.height - 1 - index / map.width
                let old = bounds[id] ?? (x, y, x, y)
                bounds[id] = (min(old.minX, x), min(old.minY, y), max(old.maxX, x), max(old.maxY, y))
                // One-cell native rounding permits diagonal contact too.
                if !touches {
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < map.width, ny >= 0, ny < map.height else { continue }
                            let neighbor = MapPixel(rawValue: map.pixels[(map.height - 1 - ny) * map.width + nx]).roomID
                            if neighbor != id && door.ids.contains(neighbor) { touches = true }
                        }
                    }
                }
            }
            guard touches, let a = bounds[ids[0]], let b = bounds[ids[1]] else { return false }
            for point in door.points {
                // Convert protocol centers into display-raster centers.
                let x = Double(point.x) - Double(origin.x) - 0.5
                let y = Double(origin.y) - Double(point.y) - 0.5
                guard x >= Double(max(a.minX, b.minX) - 1), x <= Double(min(a.maxX, b.maxX) + 1),
                      y >= Double(max(a.minY, b.minY) - 1), y <= Double(min(a.maxY, b.maxY) + 1) else { return false }
            }
        }
        return true
    }

    private static func roundedPointsMatch(_ first: [Point], _ second: [Point]) -> Bool {
        guard first.count == 2, second.count == 2 else { return false }
        func near(_ a: Point, _ b: Point) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }
        return (near(first[0], second[0]) && near(first[1], second[1])) ||
            (near(first[0], second[1]) && near(first[1], second[0]))
    }
    private static func onSegment(_ point: Point, start: MapEditPoint, end: MapEditPoint,
                                  tolerance: Double = 0) -> Bool {
        let x = Double(point.x), y = Double(point.y)
        let ax = Double(start.x), ay = Double(start.y), bx = Double(end.x), by = Double(end.y)
        let distance = abs((x - ax) * (by - ay) - (y - ay) * (bx - ax)) / hypot(bx - ax, by - ay)
        return distance <= tolerance && x >= min(ax, bx) - tolerance && x <= max(ax, bx) + tolerance
            && y >= min(ay, by) - tolerance && y <= max(ay, by) + tolerance
    }
    private static func multiset<T: Hashable>(_ values: [T]) -> [T: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
    private static func doors(_ raw: Data, roomIDs: Set<Int>) throws -> [Door] {
        guard !roomIDs.isEmpty, roomIDs.allSatisfy({ (1...255).contains($0) }) else {
            throw invalid("Door verification requires valid current rooms.")
        }
        let records = try fields(raw, limit: 1_048_576, count: 4096).filter { $0.tag == 11 }
        guard records.count <= 128 else { throw invalid("Too many map door records.") }
        return try records.map { record in
            guard record.wire == 2, let data = record.bytes else { throw invalid("Malformed map door record.") }
            let parsed = try fields(data, limit: 16_384, count: 256)
            var idValues: [Int] = [], points: [Point] = [], nonIDs = Data()
            for field in parsed {
                if field.tag == 1 {
                    if field.wire == 0, let value = field.number {
                        guard value > 0, value <= 255 else { throw invalid("Invalid door room identifier.") }
                        idValues.append(Int(value))
                    } else if field.wire == 2, let bytes = field.bytes {
                        var reader = Reader(bytes: Array(bytes))
                        while reader.offset < reader.bytes.count {
                            let value = try reader.integer()
                            guard value > 0, value <= 255, idValues.count < 8 else {
                                throw invalid("Invalid door room identifiers.")
                            }
                            idValues.append(Int(value))
                        }
                    } else { throw invalid("Malformed door room identifiers.") }
                } else {
                    nonIDs += field.raw
                    if field.tag == 2 {
                        guard field.wire == 2, let bytes = field.bytes, points.count < 64 else {
                            throw invalid("Malformed door points.")
                        }
                        points.append(try point(bytes))
                    }
                }
            }
            let ids = Set(idValues)
            guard (2...8).contains(idValues.count), ids.count == idValues.count, ids.isSubset(of: roomIDs),
                  points.count >= 2, Set(points).count == points.count else {
                throw invalid("Door identifiers or points are incomplete or duplicated.")
            }
            for tag in 3...7 {
                let values = parsed.filter { $0.tag == tag }
                guard values.count <= 1 else { throw invalid("Duplicate door settings.") }
                if let field = values.first {
                    if tag == 7 {
                        guard field.wire == 5, let bytes = field.bytes else { throw invalid("Malformed door angle.") }
                        let bits = Array(bytes).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                        guard Float(bitPattern: bits).isFinite else { throw invalid("Invalid door angle.") }
                    } else {
                        guard field.wire == 0, let value = field.number, value <= UInt32.max,
                              tag != 3 || value <= 1 else { throw invalid("Malformed door settings.") }
                    }
                }
            }
            return Door(ids: ids, points: points, nonIDs: nonIDs, raw: data,
                        onlyGeometry: parsed.allSatisfy { $0.tag == 1 || $0.tag == 2 })
        }
    }
    private static func point(_ bytes: Data) throws -> Point {
        let parsed = try fields(bytes, limit: 256, count: 16)
        // Door points observed on the X Ultra use signed int32 varints. Missing
        // scalar coordinates have protobuf's generated default zero.
        func coordinate(_ tag: Int) throws -> Int {
            let values = parsed.filter { $0.tag == tag }
            guard values.count <= 1 else { throw invalid("Duplicate door coordinate.") }
            guard let field = values.first else { return 0 }
            guard field.wire == 0, let number = field.number,
                  number <= UInt32.max || number >= UInt64.max - UInt64(Int32.max) else {
                throw invalid("Unsupported door coordinate encoding.")
            }
            let value = Int(Int32(truncatingIfNeeded: number))
            guard abs(value) <= 1_000_000 else { throw invalid("Door coordinate is out of bounds.") }
            return value
        }
        guard parsed.allSatisfy({ $0.tag == 1 || $0.tag == 2 }) else {
            throw invalid("Unsupported door point metadata.")
        }
        return try Point(x: coordinate(1), y: coordinate(2))
    }
    private static func fields(_ data: Data, limit: Int, count: Int) throws -> [Field] {
        guard data.count <= limit else { throw invalid("Door metadata exceeds its size limit.") }
        var reader = Reader(bytes: Array(data)), result: [Field] = []
        while reader.offset < reader.bytes.count {
            guard result.count < count else { throw invalid("Too many door metadata fields.") }
            let start = reader.offset, key = try reader.integer()
            guard key >> 3 > 0, key >> 3 <= 536_870_911 else { throw invalid("Invalid door metadata tag.") }
            let tag = Int(key >> 3), wire = Int(key & 7)
            var number: UInt64?, bytes: Data?
            switch wire {
            case 0: number = try reader.integer()
            case 1: bytes = try reader.take(8)
            case 2:
                let length = try reader.integer()
                guard length <= UInt64(limit) else { throw invalid("Oversized door metadata field.") }
                bytes = try reader.take(Int(length))
            case 5: bytes = try reader.take(4)
            default: throw invalid("Unsupported door metadata wire type.")
            }
            result.append(Field(tag: tag, wire: wire, number: number, bytes: bytes,
                                raw: Data(reader.bytes[start..<reader.offset])))
        }
        return result
    }
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        mutating func integer() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw invalid("Truncated door metadata.") }
                let byte = bytes[offset]; offset += 1
                guard shift != 63 || byte <= 1 else { throw invalid("Overflowing door metadata integer.") }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw invalid("Overflowing door metadata integer.")
        }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - offset else { throw invalid("Truncated door metadata.") }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }
    }
}
