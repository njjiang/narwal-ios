import XCTest
@testable import FreoCore

final class FloorplanCacheTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("freo-cache-test-" + UUID().uuidString)
    }
    private let device = RobotDevice(id: "synthetic-device", productKey: "synthetic-product", name: "Fixture")
    private func map(id: Int = 1, width: Int = 2, pixels: [UInt32] = [288, 288, 288, 288]) -> Floorplan {
        Floorplan(mapID: id, width: width, height: 2, resolution: 5,
                  rooms: [.init(id: 1, name: "Kitchen")], pixels: pixels, mapRevision: 41)
    }

    func testRoundTripAndIdenticalMapAvoidsRewrite() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FloorplanCache(directory: dir)
        try await cache.save(floorplan: map(), device: device)
        let first = try await cache.load(device: device)
        XCTAssertEqual(first?.floorplan, map())
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].lastPathComponent.contains(device.id))
        let before = try Data(contentsOf: files[0])
        try await cache.save(floorplan: map(), device: device)
        XCTAssertEqual(try Data(contentsOf: files[0]), before)
        let restarted = try await FloorplanCache(directory: dir).load(device: device)
        XCTAssertEqual(first, restarted)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDeviceAndProductIsolationAndTamperedIdentityRejected() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FloorplanCache(directory: dir)
        try await cache.save(floorplan: map(), device: device)
        let otherDevice = try await cache.load(device: .init(id: "another-device", productKey: device.productKey, name: "Other"))
        let otherProduct = try await cache.load(device: .init(id: device.id, productKey: "another-product", name: "Other"))
        XCTAssertNil(otherDevice); XCTAssertNil(otherProduct)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        record["deviceID"] = "another-device"
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        let tampered = try await cache.load(device: device)
        XCTAssertNil(tampered)
    }

    func testCorruptAndOversizedFilesAreIgnored() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FloorplanCache(directory: dir, maximumBytes: 1024)
        try await cache.save(floorplan: map(), device: device)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        try Data("not-json".utf8).write(to: file)
        let corrupt = try await cache.load(device: device); XCTAssertNil(corrupt)
        try Data(repeating: 32, count: 1025).write(to: file)
        let oversized = try await cache.load(device: device); XCTAssertNil(oversized)
    }

    func testInvalidGeometryIsNotSavedAndCannotBeLoaded() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FloorplanCache(directory: dir)
        do { try await cache.save(floorplan: map(width: 3), device: device); XCTFail("Invalid map saved") } catch { }
        try await cache.save(floorplan: map(), device: device)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var mapRecord = try XCTUnwrap(record["floorplan"] as? [String: Any]); mapRecord["width"] = 99
        record["floorplan"] = mapRecord
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        let invalid = try await cache.load(device: device); XCTAssertNil(invalid)
    }

    func testCacheRetainsAtMostEightRobots() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FloorplanCache(directory: dir)
        for index in 0..<10 {
            try await cache.save(floorplan: map(), device: .init(id: "device-\(index)", productKey: device.productKey, name: "Fixture"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).count, 8)
        let latest = try await cache.load(device: .init(id: "device-9", productKey: device.productKey, name: "Fixture"))
        XCTAssertEqual(latest?.floorplan, map())
    }
}
