import XCTest
@testable import FreoCore

final class RoomSelectionTests: XCTestCase {
    func testInitialLoadSelectsNoRooms() {
        XCTAssertEqual(RoomSelection.refreshed(previousMapID: nil, selectedRoomIDs: [], currentMapID: 7,
                                              availableRoomIDs: [1, 2, 0, -1, Int(Int32.max) + 1]), [])
    }

    func testSameMapRefreshPreservesSubsetWithoutAddingNewRooms() {
        XCTAssertEqual(RoomSelection.refreshed(previousMapID: 7, selectedRoomIDs: [2], currentMapID: 7,
                                              availableRoomIDs: [1, 2, 3]), [2])
    }

    func testSameMapEmptySelectionStaysEmpty() {
        XCTAssertEqual(RoomSelection.refreshed(previousMapID: 7, selectedRoomIDs: [], currentMapID: 7,
                                              availableRoomIDs: [1, 2]), [])
    }

    func testDeletedRoomsAreRemovedWithoutSelectingReplacements() {
        XCTAssertEqual(RoomSelection.refreshed(previousMapID: 7, selectedRoomIDs: [1, 2], currentMapID: 7,
                                              availableRoomIDs: [2, 3]), [2])
    }

    func testChangedMapClearsSelectionEvenWhenRoomNumbersAreReused() {
        XCTAssertEqual(RoomSelection.refreshed(previousMapID: 7, selectedRoomIDs: [1, 2], currentMapID: 8,
                                              availableRoomIDs: [1, 2]), [])
    }

    func testMissingOrInvalidMapCannotCarryASelection() {
        for mapID: Int? in [nil, 0, -1, Int(Int32.max) + 1] {
            XCTAssertEqual(RoomSelection.refreshed(previousMapID: 7, selectedRoomIDs: [1], currentMapID: mapID,
                                                  availableRoomIDs: [1, 2]), [])
        }
    }

    func testRefreshedSelectionCannotSilentlyNarrowAnAlreadyRequestedClean() throws {
        let device = String(repeating: "a", count: 32)
        func reference(_ roomID: Int, mapID: Int = 7) -> SiriRoomReference {
            SiriRoomReference(productKey: "EHf6cRNRGT", deviceID: device, mapID: mapID, roomID: roomID, name: "Room")
        }
        let original = [reference(1), reference(2)]
        let current = [reference(2), reference(3)]
        let visibleSelection = RoomSelection.refreshed(previousMapID: 7, selectedRoomIDs: [1, 2],
                                                       currentMapID: 7, availableRoomIDs: [2, 3])
        XCTAssertEqual(visibleSelection, [2])
        // The pending request still validates its original references, not the
        // newly intersected UI selection. It must stop before issuing a command.
        XCTAssertThrowsError(try SiriRoomReference.validate(requested: original, against: current))
        XCTAssertThrowsError(try SiriRoomReference.validate(requested: [reference(2)], against: [reference(2, mapID: 8)]))
        XCTAssertEqual(try SiriRoomReference.validate(requested: [reference(2)], against: current), [2])
    }
}
