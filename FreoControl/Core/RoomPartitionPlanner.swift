import Foundation

/// Integer cell-edge coordinates in the full display image, with Y downward.
/// These are deliberately independent of robot/world coordinate encoding.
public struct RoomGridPoint: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct RoomGridLine: Equatable, Sendable {
    public let start: RoomGridPoint
    public let end: RoomGridPoint
    public init(start: RoomGridPoint, end: RoomGridPoint) { self.start = start; self.end = end }
}

public struct RoomGridRectangle: Equatable, Sendable {
    public let minX: Int
    public let minY: Int
    public let maxXExclusive: Int
    public let maxYExclusive: Int
    public var width: Int { maxXExclusive - minX }
    public var height: Int { maxYExclusive - minY }
    public init(minX: Int, minY: Int, maxXExclusive: Int, maxYExclusive: Int) {
        self.minX = minX; self.minY = minY
        self.maxXExclusive = maxXExclusive; self.maxYExclusive = maxYExclusive
    }
    public func contains(x: Int, y: Int) -> Bool {
        x >= minX && x < maxXExclusive && y >= minY && y < maxYExclusive
    }
}

public enum RoomPartitionCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

enum RoomBoxOperation: Sendable {
    case split(Set<Int>, RoomGridLine)
    case merge(Set<Int>, Set<Int>)
}

struct RoomBoxStep: Sendable {
    let operation: RoomBoxOperation
    let regions: [Set<Int>]
}

public struct RoomPartitionPlan: Sendable {
    public let mapID: Int
    public let width: Int
    public let height: Int
    public let sourceRoomIDs: Set<Int>
    public let corner: RoomPartitionCorner
    public let rectangle: RoomGridRectangle
    public let sourceBounds: RoomGridRectangle
    public let horizontalCut: RoomGridLine
    public let verticalCut: RoomGridLine
    /// All cell indices refer to the original row-major, Y-up raster.
    public let sourceCells: Set<Int>
    public let kitchenCells: Set<Int>
    public let hallwayCells: Set<Int>
    public let horizontalRemainderCells: Set<Int>
    public let cornerBandCells: Set<Int>
    public let sideRemainderCells: Set<Int>
    fileprivate let baseline: Floorplan
    /// Existing detached all-unreachable components remain in every exact partition.
    /// This only changes connectivity checks; it makes no claim that these
    /// cells are physically uncleanable or may be changed by the firmware.
    fileprivate let connectivityExemptCells: Set<Int>
    var boxSteps: [RoomBoxStep]? = nil

    var boxOperationSummary: String? {
        guard let boxSteps else { return nil }
        let splits = boxSteps.filter { if case .split = $0.operation { true } else { false } }.count
        let merges = boxSteps.filter { if case .merge = $0.operation { true } else { false } }.count
        return "\(splits) cuts · \(merges) \(merges == 1 ? "merge" : "merges") → 2 rooms"
    }

    /// Exact preflight check. Revision/scoped device validation is separate.
    public func validateBaseline(_ latest: Floorplan) throws {
        try RoomPartitionPlanner.validateShape(latest, matching: baseline)
        guard latest.pixels == baseline.pixels,
              Set(latest.rooms.map(\.id)) == Set(baseline.rooms.map(\.id)) else {
            throw ConnectorError.invalid("The map changed. Reload it and review this room layout again.")
        }
    }

    /// Identifies each returned region from its cells, rather than predicting
    /// firmware-assigned IDs. Throws if a region is missing, split, or enlarged.
    public func matchingRoomID(cells: Set<Int>, in latest: Floorplan) throws -> Int {
        guard boxSteps != nil else {
            return try RoomPartitionPlanner.matchingRoomID(cells: cells, in: latest)
        }
        let normalized = try normalizedBoundaryCells(in: latest).union(roundedDividerCells)
        let core = cells.subtracting(normalized).filter {
            let pixel = MapPixel(rawValue: baseline.pixels[$0])
            return !pixel.isWall && !pixel.isUnreachable
        }
        let known = Set(latest.rooms.map(\.id))
        let labels = Set(core.map { MapPixel(rawValue: latest.pixels[$0]).roomID })
        guard labels.count == 1, let id = labels.first, known.contains(id),
              latest.pixels.indices.allSatisfy({ index in
                  MapPixel(rawValue: latest.pixels[index]).roomID != id ||
                      cells.contains(index) || normalized.contains(index) ||
                      ((MapPixel(rawValue: baseline.pixels[index]).isWall ||
                        MapPixel(rawValue: baseline.pixels[index]).isUnreachable) &&
                       (MapPixel(rawValue: latest.pixels[index]).isWall ||
                        MapPixel(rawValue: latest.pixels[index]).isUnreachable))
              }) else {
            throw ConnectorError.invalid("The saved room differs from the drawn boundary beyond grid rounding.")
        }
        return id
    }

    /// Native cuts can round to either adjacent grid edge.
    private var roundedDividerCells: Set<Int> {
        guard boxSteps != nil else { return [] }
        var cells = Set(sourceCells.filter { index in
            let x = index % width, y = height - 1 - index / width
            return ((x == rectangle.minX - 1 || x == rectangle.minX ||
                     x == rectangle.maxXExclusive - 1 || x == rectangle.maxXExclusive) &&
                    y >= rectangle.minY - 1 && y <= rectangle.maxYExclusive) ||
                ((y == rectangle.minY - 1 || y == rectangle.minY ||
                  y == rectangle.maxYExclusive - 1 || y == rectangle.maxYExclusive) &&
                 x >= rectangle.minX - 1 && x <= rectangle.maxXExclusive)
        })
        for step in boxSteps ?? [] {
            guard case .split(_, let line) = step.operation else { continue }
            if line.start.x == line.end.x {
                for y in max(0, min(line.start.y, line.end.y) - 1)...min(height - 1, max(line.start.y, line.end.y)) {
                    for x in [line.start.x - 1, line.start.x] where (0..<width).contains(x) {
                        let index = (height - 1 - y) * width + x
                        if sourceCells.contains(index) { cells.insert(index) }
                    }
                }
            } else {
                for x in max(0, min(line.start.x, line.end.x) - 1)...min(width - 1, max(line.start.x, line.end.x)) {
                    for y in [line.start.y - 1, line.start.y] where (0..<height).contains(y) {
                        let index = (height - 1 - y) * width + x
                        if sourceCells.contains(index) { cells.insert(index) }
                    }
                }
            }
        }
        return cells
    }

    /// Narwal re-rasterizes door edges after a split. Accept only observed flag
    /// values in the two-cell skin around the room footprint or a planned
    /// divider, covering its unreachable boundary cell and one shifted wall.
    /// Room interiors, unknown packed bits and distant rooms remain exact.
    private func normalizedBoundaryCells(in latest: Floorplan) throws -> Set<Int> {
        try RoomPartitionPlanner.validateShape(latest, matching: baseline)
        guard boxSteps != nil else { return [] }
        func neighbors(_ index: Int) -> [Int] {
            let x = index % width, y = index / width
            return [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                    y > 0 ? index - width : -1, y + 1 < height ? index + width : -1]
                .filter { $0 >= 0 }
        }
        var boundary = Set<Int>()
        for index in sourceCells {
            let old = MapPixel(rawValue: baseline.pixels[index])
            let x = index % width, y = index / width
            if x == 0 || x + 1 == width || y == 0 || y + 1 == height ||
                old.isWall || old.isUnreachable || neighbors(index).contains(where: {
                let neighbor = MapPixel(rawValue: baseline.pixels[$0])
                return !sourceCells.contains($0) || neighbor.isWall || neighbor.isUnreachable
            }) { boundary.insert(index) }
        }
        for step in boxSteps ?? [] {
            if case .split(_, let line) = step.operation {
                if line.start.x == line.end.x {
                    for y in min(line.start.y, line.end.y)..<max(line.start.y, line.end.y) {
                        for x in [line.start.x - 1, line.start.x] where (0..<width).contains(x) && (0..<height).contains(y) {
                            boundary.insert((height - 1 - y) * width + x)
                        }
                    }
                } else {
                    for x in min(line.start.x, line.end.x)..<max(line.start.x, line.end.x) {
                        for y in [line.start.y - 1, line.start.y] where (0..<width).contains(x) && (0..<height).contains(y) {
                            boundary.insert((height - 1 - y) * width + x)
                        }
                    }
                }
            }
        }
        let allowed = boundary.reduce(into: boundary) { cells, index in
            let x = index % width, y = index / width
            for row in max(0, y - 2)...min(height - 1, y + 2) {
                for column in max(0, x - 2)...min(width - 1, x + 2) {
                    cells.insert(row * width + column)
                }
            }
        }
        let flags: Set<UInt8> = [0, 1, 0x08, 0x10, 0x11, 0x18, 0x20, 0x28]
        var normalized = Set<Int>()
        for index in baseline.pixels.indices {
            let old = MapPixel(rawValue: baseline.pixels[index])
            let new = MapPixel(rawValue: latest.pixels[index])
            let delta = old.rawValue ^ new.rawValue
            guard delta != 0 else { continue }
            let labelOnly = delta & ~UInt32(0xff00) == 0
            if labelOnly && old.roomID > 0 && new.roomID > 0 {
                if !sourceCells.contains(index), allowed.contains(index),
                   (old.isWall || old.isUnreachable), (new.isWall || new.isUnreachable) {
                    normalized.insert(index)
                }
                continue
            }
            let x = index % width, y = height - 1 - index / width
            let insideSourceBounds = x >= sourceBounds.minX && x < sourceBounds.maxXExclusive &&
                y >= sourceBounds.minY && y < sourceBounds.maxYExclusive
            let oldNonNavigable = old.roomID == 0 || old.isWall || old.isUnreachable
            let newNonNavigable = new.roomID == 0 || new.isWall || new.isUnreachable
            let nonNavigableRerasterization = insideSourceBounds && oldNonNavigable && newNonNavigable
            guard allowed.contains(index) || nonNavigableRerasterization, delta & ~UInt32(0xffff) == 0,
                  flags.contains(old.flags), flags.contains(new.flags),
                  old.isWall || old.isUnreachable || old.roomID == 0 ||
                    new.isWall || new.isUnreachable || new.roomID == 0 else {
                throw ConnectorError.invalid("The robot changed map cells beyond the drawn room edges.")
            }
            normalized.insert(index)
        }
        guard normalized.count <= max(64, min(256, sourceCells.count / 20)) else {
            throw ConnectorError.invalid("The robot changed too many boundary cells to verify this edit.")
        }
        return normalized
    }

    /// Firmware may renumber surviving rooms after a merge. Match their floor
    /// footprints before accepting a changed identifier.
    func unchangedRoomMapping(from before: Floorplan, to latest: Floorplan,
                              excluding changedIDs: Set<Int>) throws -> [Int: Int] {
        let normalized = try normalizedBoundaryCells(in: latest)
        var mapping: [Int: Int] = [:]
        let known = Set(latest.rooms.map(\.id))
        for room in before.rooms where !changedIDs.contains(room.id) {
            if !before.pixels.contains(where: { MapPixel(rawValue: $0).roomID == room.id }) {
                guard latest.rooms.contains(where: { $0.id == room.id }),
                      !latest.pixels.contains(where: { MapPixel(rawValue: $0).roomID == room.id }) else {
                    throw ConnectorError.invalid("An empty saved room record changed during this edit.")
                }
                mapping[room.id] = room.id
                continue
            }
            let core = before.pixels.indices.filter {
                let pixel = MapPixel(rawValue: before.pixels[$0])
                return pixel.roomID == room.id && !pixel.isWall && !pixel.isUnreachable &&
                    !normalized.contains($0)
            }
            let ids = Set(core.map { MapPixel(rawValue: latest.pixels[$0]).roomID })
            guard !core.isEmpty, ids.count == 1, let id = ids.first, known.contains(id) else {
                throw ConnectorError.invalid("An unedited room changed beyond boundary rounding.")
            }
            mapping[room.id] = id
        }
        guard Set(mapping.values).count == mapping.count else {
            throw ConnectorError.invalid("An unedited room was unexpectedly merged.")
        }
        return mapping
    }

    /// Verifies an intermediate or final partition. Legacy plans require exact
    /// structural flags. Box plans also recognize bounded firmware rasterization
    /// at reviewed edges, while preserving interior labels and unknown bits.
    @discardableResult
    public func validatePartition(regions: [Set<Int>], latest: Floorplan) throws -> [Int] {
        try RoomPartitionPlanner.validateShape(latest, matching: baseline)
        guard !regions.isEmpty, regions.count <= 100 else {
            throw ConnectorError.invalid("The expected room partition is incomplete.")
        }
        var union = Set<Int>()
        for cells in regions {
            guard !cells.isEmpty, cells.isSubset(of: sourceCells), union.isDisjoint(with: cells) else {
                throw ConnectorError.invalid("The expected room regions overlap or leave the selected area.")
            }
            union.formUnion(cells)
        }
        guard union == sourceCells else {
            throw ConnectorError.invalid("The expected room regions do not cover the selected area.")
        }
        let normalized = try normalizedBoundaryCells(in: latest)
        let foreignMapping = boxSteps == nil ? [:] :
            try unchangedRoomMapping(from: baseline, to: latest, excluding: sourceRoomIDs)
        for index in baseline.pixels.indices {
            if normalized.contains(index) { continue }
            let changedBits = baseline.pixels[index] ^ latest.pixels[index]
            // Room operations do not authorize changes to structural flags,
            // including 0x10 (unreachable), anywhere in the selected area.
            let mutableBits: UInt32 = 0x0000_ff00
            let oldID = MapPixel(rawValue: baseline.pixels[index]).roomID
            let newID = MapPixel(rawValue: latest.pixels[index]).roomID
            let remappedForeign = foreignMapping[oldID] == newID && changedBits & ~mutableBits == 0
            guard sourceCells.contains(index) ? changedBits & ~mutableBits == 0 :
                    changedBits == 0 || remappedForeign else {
                throw ConnectorError.invalid("Other map details changed. Stop editing and inspect the current robot map.")
            }
        }
        let ids = try regions.map { try matchingRoomID(cells: $0, in: latest) }
        guard Set(ids).count == ids.count else {
            throw ConnectorError.invalid("The robot did not return the expected separate rooms.")
        }
        let unchangedRoomIDs = boxSteps == nil
            ? Set(baseline.rooms.map(\.id)).subtracting(sourceRoomIDs) : Set(foreignMapping.values)
        guard unchangedRoomIDs.isDisjoint(with: ids),
              Set(latest.rooms.map(\.id)) == unchangedRoomIDs.union(ids) else {
            throw ConnectorError.invalid("The robot’s room list changed unexpectedly. Inspect the map before continuing.")
        }
        return ids
    }

    /// Returns the discovered Kitchen and Hallway IDs, in that order.
    public func validateFinalPartition(_ latest: Floorplan) throws -> [Int] {
        try validatePartition(regions: [kitchenCells, hallwayCells], latest: latest)
    }

    /// Recognizes two already-saved rooms for naming only. This must be an exact
    /// newly reviewed baseline, never a relaxed check of a split/merge readback.
    /// Every source cell without the official unreachable flag must have the
    /// intended room label. Existing selected unreachable cells retain their
    /// actual labels, so this does not assert a solid all-cell rectangle.
    /// Returns the saved Kitchen and Hallway IDs, in that order.
    public func recognizedFinalPartition(_ latest: Floorplan) throws -> [Int] {
        if boxSteps != nil { return try validateFinalPartition(latest) }
        try validateBaseline(latest)
        guard sourceRoomIDs.count == 2 else {
            throw ConnectorError.invalid("Naming the saved layout requires two current rooms.")
        }
        let regions = [kitchenCells, hallwayCells]
        let ids = try regions.map { cells -> Int in
            let labels = Set(cells.compactMap { index -> Int? in
                let pixel = MapPixel(rawValue: baseline.pixels[index])
                return pixel.isUnreachable ? nil : pixel.roomID
            })
            guard labels.count == 1, let id = labels.first, sourceRoomIDs.contains(id) else {
                throw ConnectorError.invalid("The saved room labels do not match the reviewed two-room layout.")
            }
            return id
        }
        guard Set(ids) == sourceRoomIDs else {
            throw ConnectorError.invalid("The saved areas must be separate rooms.")
        }
        for (cells, id) in zip(regions, ids) {
            guard cells.allSatisfy({ index in
                let pixel = MapPixel(rawValue: baseline.pixels[index])
                return pixel.roomID == id || (pixel.isUnreachable && sourceRoomIDs.contains(pixel.roomID))
            }) else {
                throw ConnectorError.invalid("The saved layout contains an unexpected room label.")
            }
        }
        // Freeze the complete actual room footprints, including every existing
        // unreachable cell. These are not replaced by the ideal divider masks.
        let actualRegions = ids.map { id in
            Set(sourceCells.filter { MapPixel(rawValue: baseline.pixels[$0]).roomID == id })
        }
        _ = try validatePartition(regions: actualRegions, latest: latest)
        return ids
    }
}

public enum RoomPartitionPlanner {
    public static func sourceBounds(floorplan: Floorplan, sourceRoomIDs: Set<Int>) throws -> RoomGridRectangle {
        try source(floorplan: floorplan, roomIDs: sourceRoomIDs).bounds
    }

    public static func make(floorplan: Floorplan, sourceRoomIDs: Set<Int>,
                            rectangle: RoomGridRectangle) throws -> RoomPartitionPlan {
        let source = try source(floorplan: floorplan, roomIDs: sourceRoomIDs)
        let bounds = source.bounds
        // Freeze detached components consisting entirely of cells already marked
        // unreachable before any proposed split. Never exempt new disconnected cells
        // or alter the original bounds, selected cells or expected readback.
        let connectivityExempt = detachedUnreachableComponents(in: source.cells, floorplan: floorplan)
        let connectedSource = source.cells.subtracting(connectivityExempt)
        guard connected(connectedSource, width: floorplan.width, height: floorplan.height) else {
            throw ConnectorError.invalid("The selected area contains disconnected cells in the robot’s map. Choose connected rooms before editing.")
        }
        guard Set(connectedSource.map { MapPixel(rawValue: floorplan.pixels[$0]).roomID }) == sourceRoomIDs else {
            throw ConnectorError.invalid("A selected room has no connected area beyond detached unreachable components. Choose rooms with a connected area to edit.")
        }
        guard rectangle.minX >= bounds.minX, rectangle.minY >= bounds.minY,
              rectangle.maxXExclusive <= bounds.maxXExclusive, rectangle.maxYExclusive <= bounds.maxYExclusive,
              rectangle.minX < rectangle.maxXExclusive, rectangle.minY < rectangle.maxYExclusive,
              rectangle.width < bounds.width, rectangle.height < bounds.height else {
            throw ConnectorError.invalid("Place a smaller corner rectangle entirely inside the selected rooms.")
        }
        let left = rectangle.minX == bounds.minX, right = rectangle.maxXExclusive == bounds.maxXExclusive
        let top = rectangle.minY == bounds.minY, bottom = rectangle.maxYExclusive == bounds.maxYExclusive
        guard left != right, top != bottom else {
            throw ConnectorError.invalid("The rectangle must meet two outer edges of the selected area.")
        }
        let corner: RoomPartitionCorner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
        let splitX = left ? rectangle.maxXExclusive : rectangle.minX
        let splitY = top ? rectangle.maxYExclusive : rectangle.minY
        var kitchen = Set<Int>(), hallway = Set<Int>(), horizontalRemainder = Set<Int>()
        var cornerBand = Set<Int>(), sideRemainder = Set<Int>()
        for index in source.cells {
            let x = index % floorplan.width, y = floorplan.height - 1 - index / floorplan.width
            let inBand = top ? y < splitY : y >= splitY
            if !inBand { horizontalRemainder.insert(index); hallway.insert(index) }
            else {
                cornerBand.insert(index)
                if rectangle.contains(x: x, y: y) { kitchen.insert(index) }
                else { sideRemainder.insert(index); hallway.insert(index) }
            }
        }
        // Unassigned space and known foreign unreachable cells remain untouched holes
        // in the drawn rectangle, never part of any selected region. Every other
        // foreign room cell blocks overlap; cut intersections are checked below
        // without this exception. This does not create a physical no-go zone.
        var overlappingRoomIDs = Set<Int>()
        let knownRoomIDs = Set(floorplan.rooms.map(\.id))
        for y in rectangle.minY..<rectangle.maxYExclusive {
            for x in rectangle.minX..<rectangle.maxXExclusive {
                let index = (floorplan.height - 1 - y) * floorplan.width + x
                let pixel = MapPixel(rawValue: floorplan.pixels[index]), room = pixel.roomID
                if room != 0 && !sourceRoomIDs.contains(room),
                   !(pixel.isUnreachable && knownRoomIDs.contains(room)) { overlappingRoomIDs.insert(room) }
            }
        }
        if !overlappingRoomIDs.isEmpty {
            let names = overlappingRoomIDs.sorted().map { id in
                floorplan.rooms.first(where: { $0.id == id })?.name ?? "Room \(id)"
            }.joined(separator: ", ")
            throw ConnectorError.invalid("The rectangle overlaps \(names). Move the boundary or change the selected area.")
        }
        let regions: [(Set<Int>, String)] = [
            (kitchen, "The corner room would be empty or disconnected. Move its corner and try again."),
            (hallway, "The remaining room would be empty or disconnected. Adjust the boundaries and try again."),
            (horizontalRemainder, "The horizontal cut leaves an empty or disconnected section. Move the horizontal boundary."),
            (cornerBand, "The horizontal cut leaves an empty or disconnected corner side. Move the horizontal boundary."),
            (sideRemainder, "The vertical cut leaves an empty or disconnected side section. Move the vertical boundary."),
        ]
        for (cells, message) in regions {
            guard connected(cells.subtracting(connectivityExempt), width: floorplan.width, height: floorplan.height) else {
                throw ConnectorError.invalid(message)
            }
        }
        func index(x: Int, y: Int) -> Int { (floorplan.height - 1 - y) * floorplan.width + x }
        // A cut only needs to sever adjacency edges joining its two regions.
        // Extending it across the entire bounding box can reach an unrelated
        // room beside a concave wing. Keep every necessary adjacency edge,
        // and still inspect the complete intervening segment below.
        let horizontalEdges = (bounds.minX..<bounds.maxXExclusive).filter { x in
            source.cells.contains(index(x: x, y: splitY - 1)) && source.cells.contains(index(x: x, y: splitY))
        }
        let bandStart = top ? bounds.minY : splitY
        let bandEnd = top ? splitY : bounds.maxYExclusive
        let verticalEdges = (bandStart..<bandEnd).filter { y in
            cornerBand.contains(index(x: splitX - 1, y: y)) && cornerBand.contains(index(x: splitX, y: y))
        }
        guard let firstX = horizontalEdges.first, let lastX = horizontalEdges.last,
              let firstY = verticalEdges.first, let lastY = verticalEdges.last else {
            throw ConnectorError.invalid("A divider does not join two parts of the selected area. Move the boundary and try again.")
        }
        let horizontalCut = RoomGridLine(start: .init(x: firstX, y: splitY),
                                         end: .init(x: lastX + 1, y: splitY))
        let verticalCut = RoomGridLine(start: .init(x: splitX, y: firstY),
                                       end: .init(x: splitX, y: lastY + 1))
        // Both neighboring cells along the whole resulting segment must avoid
        // foreign rooms, including gaps between separate adjacency runs.
        func checkCutNeighbor(x: Int, y: Int) throws {
            guard (0..<floorplan.width).contains(x), (0..<floorplan.height).contains(y) else { return }
            let index = (floorplan.height - 1 - y) * floorplan.width + x
            let id = MapPixel(rawValue: floorplan.pixels[index]).roomID
            guard id == 0 || sourceRoomIDs.contains(id) else {
                throw ConnectorError.invalid("A divider crosses another room. Choose a different corner or selected area.")
            }
        }
        for x in horizontalCut.start.x..<horizontalCut.end.x {
            try checkCutNeighbor(x: x, y: splitY - 1)
            try checkCutNeighbor(x: x, y: splitY)
        }
        for y in verticalCut.start.y..<verticalCut.end.y {
            try checkCutNeighbor(x: splitX - 1, y: y)
            try checkCutNeighbor(x: splitX, y: y)
        }
        return RoomPartitionPlan(mapID: floorplan.mapID, width: floorplan.width, height: floorplan.height,
            sourceRoomIDs: sourceRoomIDs, corner: corner, rectangle: rectangle, sourceBounds: bounds,
            horizontalCut: horizontalCut, verticalCut: verticalCut, sourceCells: source.cells,
            kitchenCells: kitchen, hallwayCells: hallway, horizontalRemainderCells: horizontalRemainder,
            cornerBandCells: cornerBand, sideRemainderCells: sideRemainder, baseline: floorplan,
            connectivityExemptCells: connectivityExempt)
    }

    public static func makeBox(floorplan map: Floorplan, sourceRoomIDs ids: Set<Int>,
                               rectangle requestedBox: RoomGridRectangle) throws -> RoomPartitionPlan {
        let (cells, bounds) = try source(floorplan: map, roomIDs: ids)
        guard requestedBox.minX >= bounds.minX, requestedBox.minY >= bounds.minY,
              requestedBox.maxXExclusive <= bounds.maxXExclusive,
              requestedBox.maxYExclusive <= bounds.maxYExclusive,
              requestedBox.minX < requestedBox.maxXExclusive, requestedBox.minY < requestedBox.maxYExclusive else {
            throw ConnectorError.invalid("Draw the box inside the selected area.")
        }
        let roomBounds = try ids.sorted().map { try sourceBounds(floorplan: map, sourceRoomIDs: [$0]) }
        let xEdges = roomBounds.flatMap { [$0.minX, $0.maxXExclusive] }
        let yEdges = roomBounds.flatMap { [$0.minY, $0.maxYExclusive] }
        func snapped(_ value: Int, edges: [Int]) -> Int {
            let nearby = Set(edges.filter { abs($0 - value) <= 1 })
            if nearby.contains(value) { return value }
            return nearby.count == 1 ? nearby.first! : value
        }
        let box = RoomGridRectangle(minX: snapped(requestedBox.minX, edges: xEdges),
            minY: snapped(requestedBox.minY, edges: yEdges),
            maxXExclusive: snapped(requestedBox.maxXExclusive, edges: xEdges),
            maxYExclusive: snapped(requestedBox.maxYExclusive, edges: yEdges))
        guard box.width > 0, box.height > 0, box.minX >= bounds.minX, box.minY >= bounds.minY,
              box.maxXExclusive <= bounds.maxXExclusive, box.maxYExclusive <= bounds.maxYExclusive else {
            throw ConnectorError.invalid("Draw the box inside the selected area.")
        }
        let exempt = detachedUnreachableComponents(in: cells, floorplan: map)
        // Narwal's room editor requires each split piece to be at least 0.5 m².
        // Resolution is millimeters per grid cell on this map format.
        let minimumCells: Int
        if let resolution = map.resolution, resolution > 0 {
            minimumCells = Int(ceil(500_000.0 / (Double(resolution) * Double(resolution))))
        } else {
            minimumCells = 1
        }
        func largeEnough(_ region: Set<Int>) -> Bool {
            region.subtracting(exempt).count >= minimumCells
        }
        func connectedRegion(_ region: Set<Int>) -> Bool {
            connected(region.subtracting(exempt), width: map.width, height: map.height)
        }
        func index(_ x: Int, _ y: Int) -> Int { (map.height - 1 - y) * map.width + x }
        func room(_ i: Int) -> Int { MapPixel(rawValue: map.pixels[i]).roomID }
        let known = Set(map.rooms.map(\.id))
        for y in box.minY..<box.maxYExclusive {
            for x in box.minX..<box.maxXExclusive {
                let i = index(x, y), id = room(i)
                if id != 0 && !ids.contains(id) &&
                    !(known.contains(id) && MapPixel(rawValue: map.pixels[i]).isUnreachable) {
                    throw ConnectorError.invalid("The box overlaps an unselected room.")
                }
            }
        }
        let target = Set(cells.filter { box.contains(x: $0 % map.width, y: map.height - 1 - $0 / map.width) })
        let remainder = cells.subtracting(target)
        guard connectedRegion(target), connectedRegion(remainder) else {
            throw ConnectorError.invalid("The box and the remaining floor must each form one connected room.")
        }
        guard largeEnough(target), largeEnough(remainder) else {
            throw ConnectorError.invalid("Each room must be at least 0.5 m². Enlarge the box or the remaining area.")
        }
        var regions = ids.sorted().map { id in Set(cells.filter { room($0) == id }) }
        var steps = [RoomBoxStep]()
        if ids.count == 2 {
            let line = RoomGridLine(start: .init(x: box.minX, y: box.minY), end: .init(x: box.minX, y: box.minY))
            let saved = RoomPartitionPlan(mapID: map.mapID, width: map.width, height: map.height,
                sourceRoomIDs: ids, corner: .topLeft, rectangle: box, sourceBounds: bounds,
                horizontalCut: line, verticalCut: line, sourceCells: cells, kitchenCells: target,
                hallwayCells: remainder, horizontalRemainderCells: [], cornerBandCells: [],
                sideRemainderCells: [], baseline: map, connectivityExemptCells: exempt, boxSteps: [])
            if (try? saved.validateFinalPartition(map)) != nil { return saved }
        }
        // Try both axes and both edges. A concave footprint may admit only one order.
        let edges = [(true, box.minX), (true, box.maxXExclusive),
                     (false, box.minY), (false, box.maxYExclusive)]
        func cuts(_ region: Set<Int>, available: [Int]) -> [(Set<Int>, Set<Int>, RoomGridLine)]? {
            if region.isSubset(of: target) || region.isDisjoint(with: target) { return [] }
            for edge in available {
                let (vertical, coordinate) = edges[edge]
                let low = Set(region.filter {
                    (vertical ? $0 % map.width : map.height - 1 - $0 / map.width) < coordinate
                })
                let high = region.subtracting(low)
                guard largeEnough(low), largeEnough(high),
                      connectedRegion(low), connectedRegion(high) else { continue }
                let axisRange = vertical ? bounds.minY..<bounds.maxYExclusive : bounds.minX..<bounds.maxXExclusive
                func neighbors(_ along: Int) -> (Int, Int) {
                    vertical ? (index(coordinate - 1, along), index(coordinate, along))
                             : (index(along, coordinate - 1), index(along, coordinate))
                }
                let crossings = axisRange.filter { along in
                    let (a, b) = neighbors(along)
                    return low.contains(a) && high.contains(b)
                }
                guard let first = crossings.first, let last = crossings.last,
                      (first...last).allSatisfy({ along in
                          let (a, b) = neighbors(along)
                          return [a, b].allSatisfy { region.contains($0) || room($0) == 0 }
                      }) else { continue }
                let line = vertical
                    ? RoomGridLine(start: .init(x: coordinate, y: first), end: .init(x: coordinate, y: last + 1))
                    : RoomGridLine(start: .init(x: first, y: coordinate), end: .init(x: last + 1, y: coordinate))
                let next = available.filter { $0 != edge }
                if let lowCuts = cuts(low, available: next), let highCuts = cuts(high, available: next) {
                    return [(region, low, line)] + lowCuts + highCuts
                }
            }
            return nil
        }
        // A box spanning existing rooms can leave a tiny temporary strip
        // when each room is cut independently. Join those saved pieces first.
        if regions.count > 1 && !regions.allSatisfy({ cuts($0, available: Array(edges.indices)) != nil }) {
            while regions.count > 1 {
                var pair: (Int, Int)?
                for first in regions.indices {
                    if let second = regions.indices.dropFirst(first + 1).first(where: {
                        connectedRegion(regions[first].union(regions[$0]))
                    }) {
                        pair = (first, second)
                        break
                    }
                }
                guard let (first, second) = pair else {
                    throw ConnectorError.invalid("The selected saved pieces cannot be joined into one area.")
                }
                let firstCells = regions[first], secondCells = regions[second]
                regions.remove(at: second)
                regions.remove(at: first)
                regions.append(firstCells.union(secondCells))
                steps.append(.init(operation: .merge(firstCells, secondCells), regions: regions))
            }
        }
        for original in regions {
            guard let splits = cuts(original, available: Array(edges.indices)) else {
                throw ConnectorError.invalid("This box needs a temporary room smaller than 0.5 m², or a disconnected cut. Move an edge to the existing room boundary, or enlarge the box.")
            }
            for (parent, low, line) in splits {
                guard let position = regions.firstIndex(of: parent) else { throw MapEditError.staleSnapshot }
                regions.remove(at: position)
                regions += [low, parent.subtracting(low)]
                steps.append(.init(operation: .split(parent, line), regions: regions))
            }
        }
        for area in [target, remainder] {
            while !regions.contains(area) {
                let pieces = regions.filter { $0.isSubset(of: area) }
                var pair: (Set<Int>, Set<Int>)?
                for (i, first) in pieces.enumerated() {
                    if let second = pieces.dropFirst(i + 1).first(where: { connectedRegion(first.union($0)) }) {
                        pair = (first, second)
                        break
                    }
                }
                guard let (first, second) = pair else {
                    throw ConnectorError.invalid("The resulting sections cannot be joined into one room.")
                }
                regions.removeAll { $0 == first || $0 == second }
                regions.append(first.union(second))
                steps.append(.init(operation: .merge(first, second), regions: regions))
            }
        }
        // The existing corner plan fields are used only by the legacy corner transaction.
        let unusedLine = RoomGridLine(start: .init(x: box.minX, y: box.minY), end: .init(x: box.minX, y: box.minY))
        return RoomPartitionPlan(mapID: map.mapID, width: map.width, height: map.height, sourceRoomIDs: ids,
            corner: .topLeft, rectangle: box, sourceBounds: bounds, horizontalCut: unusedLine, verticalCut: unusedLine,
            sourceCells: cells, kitchenCells: target, hallwayCells: remainder,
            horizontalRemainderCells: [], cornerBandCells: [], sideRemainderCells: [],
            baseline: map, connectivityExemptCells: exempt, boxSteps: steps)
    }

    /// Fresh-read precondition before the first edit, never a restore promise.
    public static func validate(current: MapSnapshot, against baseline: MapSnapshot) throws {
        guard current.productKey == baseline.productKey, current.deviceID == baseline.deviceID,
              current.mapID == baseline.mapID, current.mapVersion == baseline.mapVersion,
              current.editVersion == baseline.editVersion,
              current.staticMapPayload == baseline.staticMapPayload else {
            throw ConnectorError.invalid("The saved map changed. Reload it and review the edit again.")
        }
        try validateShape(current.floorplan, matching: baseline.floorplan)
        guard current.floorplan.mapID == current.mapID, baseline.floorplan.mapID == baseline.mapID,
              current.floorplan.pixels == baseline.floorplan.pixels,
              Set(current.floorplan.rooms.map(\.id)) == Set(baseline.floorplan.rooms.map(\.id)) else {
            throw ConnectorError.invalid("The map snapshot no longer matches the reviewed layout.")
        }
    }

    public static func matchingRoomID(cells: Set<Int>, in floorplan: Floorplan) throws -> Int {
        try validateGrid(floorplan)
        guard let first = cells.first, cells.allSatisfy({ floorplan.pixels.indices.contains($0) }) else {
            throw ConnectorError.invalid("The expected room region is empty or outside this map.")
        }
        let known = Set(floorplan.rooms.map(\.id))
        guard let id = MapPixel(rawValue: floorplan.pixels[first]).knownRoomID(in: known),
              cells.allSatisfy({ MapPixel(rawValue: floorplan.pixels[$0]).roomID == id }) else {
            throw ConnectorError.invalid("The robot’s room shape differs from the reviewed layout.")
        }
        for (index, raw) in floorplan.pixels.enumerated() where MapPixel(rawValue: raw).roomID == id {
            guard cells.contains(index) else {
                throw ConnectorError.invalid("The returned room extends outside the expected region.")
            }
        }
        return id
    }

    fileprivate static func validateShape(_ latest: Floorplan, matching baseline: Floorplan) throws {
        try validateGrid(latest)
        guard latest.mapID == baseline.mapID, latest.width == baseline.width, latest.height == baseline.height,
              latest.resolution == baseline.resolution else {
            throw ConnectorError.invalid("The map or its geometry changed. Reload it before editing.")
        }
    }

    private static func validateGrid(_ floorplan: Floorplan) throws {
        guard floorplan.mapID > 0, floorplan.width > 0, floorplan.height > 0,
              floorplan.width <= 4096, floorplan.height <= 4096,
              floorplan.width <= 1_000_000 / floorplan.height,
              floorplan.pixels.count == floorplan.width * floorplan.height,
              !floorplan.rooms.isEmpty, floorplan.rooms.count <= 100,
              Set(floorplan.rooms.map(\.id)).count == floorplan.rooms.count else {
            throw ConnectorError.invalid("The saved floorplan is incomplete or too large to edit.")
        }
    }

    private static func source(floorplan: Floorplan, roomIDs: Set<Int>) throws
        -> (cells: Set<Int>, bounds: RoomGridRectangle) {
        try validateGrid(floorplan)
        let known = Set(floorplan.rooms.map(\.id))
        guard (1...8).contains(roomIDs.count), roomIDs.isSubset(of: known),
              roomIDs.allSatisfy({ (1...255).contains($0) }) else {
            throw ConnectorError.invalid("Select one or two current rooms, or three saved divider pieces.")
        }
        var cells = Set<Int>(), found = Set<Int>()
        var minX = floorplan.width, minY = floorplan.height, maxX = -1, maxY = -1
        for (index, raw) in floorplan.pixels.enumerated() {
            let room = MapPixel(rawValue: raw).roomID
            if roomIDs.contains(room) {
                cells.insert(index); found.insert(room)
                let x = index % floorplan.width, y = floorplan.height - 1 - index / floorplan.width
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard found == roomIDs else {
            throw ConnectorError.invalid("A selected room has no current map cells. Reload the map.")
        }
        return (cells, RoomGridRectangle(minX: minX, minY: minY, maxXExclusive: maxX + 1, maxYExclusive: maxY + 1))
    }

    private static func detachedUnreachableComponents(in cells: Set<Int>, floorplan: Floorplan) -> Set<Int> {
        let width = floorplan.width, height = floorplan.height
        var remaining = cells, components = [Set<Int>]()
        while let first = remaining.first {
            remaining.remove(first)
            var queue = [first], cursor = 0
            while cursor < queue.count {
                let cell = queue[cursor]; cursor += 1
                let x = cell % width, y = cell / width
                let neighbors = [x > 0 ? cell - 1 : -1, x + 1 < width ? cell + 1 : -1,
                                 y > 0 ? cell - width : -1, y + 1 < height ? cell + width : -1]
                for neighbor in neighbors where remaining.remove(neighbor) != nil { queue.append(neighbor) }
            }
            components.append(Set(queue))
        }
        // A connected source needs no exception. For a disconnected source,
        // require one uniquely largest component containing cells without the
        // unreachable flag. Any other such component blocks the edit.
        guard components.count > 1 else { return [] }
        components.sort { $0.count > $1.count }
        let main = components[0]
        guard main.count > components[1].count,
              main.contains(where: { !MapPixel(rawValue: floorplan.pixels[$0]).isUnreachable }),
              components.dropFirst().allSatisfy({ $0.allSatisfy { MapPixel(rawValue: floorplan.pixels[$0]).isUnreachable } }) else {
            return []
        }
        return components.dropFirst().reduce(into: Set<Int>()) { $0.formUnion($1) }
    }

    private static func connected(_ cells: Set<Int>, width: Int, height: Int) -> Bool {
        guard let first = cells.first else { return false }
        var seen = Set([first]), queue = [first], cursor = 0
        while cursor < queue.count {
            let cell = queue[cursor]; cursor += 1
            let x = cell % width, y = cell / width
            let candidates = [x > 0 ? cell - 1 : -1, x + 1 < width ? cell + 1 : -1,
                              y > 0 ? cell - width : -1, y + 1 < height ? cell + width : -1]
            for neighbor in candidates where cells.contains(neighbor) && seen.insert(neighbor).inserted {
                queue.append(neighbor)
            }
        }
        return seen.count == cells.count
    }
}
