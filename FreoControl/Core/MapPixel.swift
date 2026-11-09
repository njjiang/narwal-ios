/// A read-only view of one original packed map cell. Unknown bits stay intact.
public struct MapPixel: Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    // Verified in the official app's MapEngineRasterParserImp._parseMapGrids:
    // unboxed cell >> 8, then AND 0xff (instructions 0x11278f8–0x1127900).
    // Higher bits describe other attributes and must never become room IDs.
    public var roomID: Int { Int((rawValue >> 8) & 0xff) }
    public var flags: UInt8 { UInt8(rawValue & 0xff) }
    // Official RoomSplitGridMap: _buildRoomSplitSnapshot places raw & 0x20
    // in field 0x2b (isWallAt) and raw & 0x10 in field 0x2f
    // (isUnreachableAt). The geometric _isRoomEdge4 test is unrelated.
    public var isWall: Bool { rawValue & 0x20 != 0 }
    public var isUnreachable: Bool { rawValue & 0x10 != 0 }

    /// Rendering and hit-testing must agree with the current map's room catalog.
    public func knownRoomID(in roomIDs: Set<Int>) -> Int? {
        let id = roomID
        return id > 0 && roomIDs.contains(id) ? id : nil
    }
}
