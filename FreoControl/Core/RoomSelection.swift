import Foundation

/// Refreshing room metadata must not expand a user's cleaning selection.
public enum RoomSelection {
    public static func refreshed(previousMapID: Int?, selectedRoomIDs: Set<Int>,
                                 currentMapID: Int?, availableRoomIDs: Set<Int>) -> Set<Int> {
        guard let currentMapID, (1...Int(Int32.max)).contains(currentMapID) else { return [] }
        let available = availableRoomIDs.filter { (1...Int(Int32.max)).contains($0) }
        guard let previousMapID else { return [] }
        guard previousMapID == currentMapID else { return [] }
        return selectedRoomIDs.intersection(available)
    }
}
