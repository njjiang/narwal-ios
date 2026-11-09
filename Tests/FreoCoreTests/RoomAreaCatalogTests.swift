import XCTest
@testable import FreoCore

final class RoomAreaCatalogTests: XCTestCase {
    func testEmptyMetadataRoomIsExcludedWithoutChangingMap() {
        let rooms = [RobotRoom(id: 1, name: "Living room"), RobotRoom(id: 3, name: "Room 3"),
                     RobotRoom(id: 8, name: "Kitchen")]
        let pixels: [UInt32] = [0x101, 0x10000801, 0, 0x801]
        let map = Floorplan(mapID: 1, width: 2, height: 2, resolution: 60,
                            rooms: rooms, pixels: pixels, mapRevision: 72)
        XCTAssertEqual(map.roomsWithArea.map(\.id), [1, 8])
        XCTAssertEqual(map.rooms, rooms)
        XCTAssertEqual(map.pixels, pixels)
    }

    func testRoomThreeIsKeptWhenItActuallyHasArea() {
        let room = RobotRoom(id: 3, name: "Room 3")
        let map = Floorplan(mapID: 1, width: 1, height: 1, resolution: 60,
                            rooms: [room], pixels: [0x301], mapRevision: 73)
        XCTAssertEqual(map.roomsWithArea, [room])
    }

    func testIncompleteRasterDoesNotHideRooms() {
        let rooms = [RobotRoom(id: 1, name: "Living room")]
        let map = Floorplan(mapID: 1, width: 2, height: 2, resolution: 60,
                            rooms: rooms, pixels: [], mapRevision: 72)
        XCTAssertEqual(map.roomsWithArea, rooms)
    }
}
