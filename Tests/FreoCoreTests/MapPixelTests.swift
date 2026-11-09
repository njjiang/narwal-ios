import XCTest
@testable import FreoCore

final class MapPixelTests: XCTestCase {
    func testHigherAttributesDoNotCreatePhantomRooms() {
        let base = MapPixel(rawValue: 0x00000601)
        let attributed = MapPixel(rawValue: 0x10000601)
        XCTAssertEqual(base.roomID, 6)
        XCTAssertEqual(attributed.roomID, 6)
        XCTAssertEqual(base.flags, attributed.flags)
        XCTAssertEqual(attributed.knownRoomID(in: [1, 6, 8]), 6)
        XCTAssertEqual(attributed.rawValue, 0x10000601)
    }

    func testAllEightRoomBitsArePreserved() {
        // A six-bit mask would silently alias room64 to0 and room255 to63.
        for id in [1, 63, 64, 127, 128, 255] {
            let pixel = MapPixel(rawValue: 0xa5ab0001 | UInt32(id) << 8)
            XCTAssertEqual(pixel.roomID, id)
            XCTAssertEqual(pixel.knownRoomID(in: [id]), id)
        }
    }

    func testZeroRoomAndUnknownCatalogEntriesCannotBeSelected() {
        XCTAssertNil(MapPixel(rawValue: 0).knownRoomID(in: [0, 1]))
        XCTAssertNil(MapPixel(rawValue: 0x10000020).knownRoomID(in: [0, 1]))
        XCTAssertNil(MapPixel(rawValue: 0x10000701).knownRoomID(in: [1, 6, 8]))
        XCTAssertEqual(MapPixel(rawValue: 0x10000701).roomID, 7)
    }

    func testUnreachableAndWallFlagsRemainIndependentOfRoomAndOtherAttributes() {
        let pixel = MapPixel(rawValue: 0xfedc0613)
        XCTAssertEqual(pixel.roomID, 6)
        XCTAssertEqual(pixel.flags, 0x13)
        XCTAssertTrue(pixel.isUnreachable)
        XCTAssertFalse(MapPixel(rawValue: 0xfedc0603).isUnreachable)
        XCTAssertFalse(pixel.isWall)
        let wall = MapPixel(rawValue: 0xfedc0623)
        XCTAssertTrue(wall.isWall)
        XCTAssertFalse(wall.isUnreachable)
        let both = MapPixel(rawValue: 0xfedc0633)
        XCTAssertTrue(both.isWall); XCTAssertTrue(both.isUnreachable)
        XCTAssertEqual(both.roomID, 6)
        XCTAssertEqual(pixel.rawValue, 0xfedc0613)
    }

    func testMaximumRawValueRemainsUnsignedAndUnchanged() {
        let pixel = MapPixel(rawValue: .max)
        XCTAssertEqual(pixel.roomID, 255)
        XCTAssertEqual(pixel.flags, 255)
        XCTAssertEqual(pixel.rawValue, UInt32.max)
    }
}
