import Foundation
import XCTest
@testable import FreoCore

final class NarwalHistoryTests: XCTestCase {
    private let robot = RobotDevice(id: String(repeating: "a", count: 32), productKey: "EHf6cRNRGT", name: "Synthetic robot")
    private let recordID: Int64 = 9_007_199_254_740_993
    private let start: Int64 = 1_700_000_000
    private func envelope(_ result: Any) throws -> Data { try JSONSerialization.data(withJSONObject: ["code": 0, "success": true, "result": result]) }
    private func listItem(id: Int64? = nil, device: RobotDevice? = nil) -> [String: Any] {
        let device = device ?? robot
        return ["record_id": id ?? recordID, "product_id": device.productKey, "device_id": device.id,
                "start_time": start, "end_time": start + 1800, "duration": 900, "record_status": 2, "map_id": 1,
                "room_infos": [["room_id": 1, "type": 4, "custom_name": "Test kitchen"], ["room_id": 2, "type": 10, "custom_name": "Test hallway"]],
                "clean_task": ["task_type": 6, "items": [["zone": ["zone_id": 1, "zone_type": 1], "param": ["mode": 2]]]]]
    }
    private func summary(_ item: [String: Any]? = nil, device: RobotDevice? = nil) throws -> CloudCleaningRecord {
        let records = try NarwalHistoryCodec.records(envelope([item ?? listItem()]), device: device ?? robot)
        return try XCTUnwrap(records.first)
    }
    private func detailItem(id: Int64? = nil, device: RobotDevice? = nil) -> [String: Any] {
        let device = device ?? robot
        let points: [(Float, Float)] = [(0, 10), (1, 9), (2, 8), (3, 7)]
        return ["record_id": id ?? recordID, "product_id": device.productKey, "device_id": device.id,
                "start_time": start, "end_time": start + 1800, "map_id": 1, "map_version": 9,
                "width": 10, "height": 10, "resolution": 60, "border": ["bottom": 0, "top": 10, "left": 0, "right": 10],
                "room_infos": [["room_id": 1, "type": 4, "custom_name": "Test kitchen"]],
                // Synthetic zlib MapData with100room1 cells; no private map.
                "map_data_format": 3, "map_data": "eJzjOsHYyDQ8IADYEjQA",
                "robot_trajectory_format": 2, "robot_trajectory": RouteFixture.path(points).base64EncodedString(),
                "trajectory_infos": [["trajectory_type": 1, "index": 1], ["trajectory_type": 4, "index": 2]],
                "trajectory_start_indices": [1, 2], "trajectory_arcs": NSNull(),
                // These values are deliberately not read or followed.
                "map_path": "https://untrusted.invalid/private", "user_uuid": "not retained"]
    }

    func testLargeIDsRemainExactAndModeComesFromParametersNotReportTaskType() throws {
        var item = listItem(); item["task_type"] = 3
        let record = try summary(item)
        XCTAssertEqual(record.id, "9007199254740993")
        XCTAssertTrue(record.matches(device: robot)); XCTAssertEqual(record.modeName, "Vacuum")
        XCTAssertEqual(record.roomNames, ["Test kitchen"])
        XCTAssertEqual(record.durationSeconds, 900)
        XCTAssertEqual(record.endedAt?.timeIntervalSince(record.startedAt), 1800)
        XCTAssertEqual(record.statusCode, 2)
        // Decimal-string JSON IDs are also exact; floating/scientific values
        // must never round into a neighboring record identifier.
        item["record_id"] = "9007199254740993"
        XCTAssertEqual(try summary(item).id, record.id)
        for invalid: Any in [true, 1.5, "9.007199254740993e15", "09007199254740993", "9223372036854775808", -1] {
            item["record_id"] = invalid; XCTAssertThrowsError(try summary(item))
        }
    }

    func testListRejectsCrossDeviceDuplicateAndMalformedMetadata() throws {
        let other = RobotDevice(id: String(repeating: "b", count: 32), productKey: robot.productKey, name: "Other")
        XCTAssertThrowsError(try NarwalHistoryCodec.records(envelope([listItem(device: other)]), device: robot))
        XCTAssertThrowsError(try NarwalHistoryCodec.records(envelope([listItem(), listItem()]), device: robot))
        var item = listItem(); item["start_time"] = true; XCTAssertThrowsError(try summary(item))
        item = listItem(); item["end_time"] = start - 1; XCTAssertThrowsError(try summary(item))
        item = listItem(); item["room_infos"] = [["room_id": 1, "custom_name": "bad\nname"]]
        XCTAssertThrowsError(try summary(item))
        XCTAssertThrowsError(try NarwalHistoryCodec.records(Data(repeating: 0, count: 8 * 1024 * 1024 + 1), device: robot))
    }

    func testMixedAndUnknownModeMetadataNeverGuessesCurrentPicker() throws {
        var item = listItem()
        item["clean_task"] = ["items": [["zone": ["zone_id": 1, "zone_type": 1], "param": ["mode": 2]], ["zone": ["zone_id": 2, "zone_type": 1], "param": ["mode": 5]]]]
        XCTAssertEqual(try summary(item).modeName, "Mixed room settings")
        XCTAssertEqual(try summary(item).roomNames, ["Test kitchen", "Test hallway"])
        item["clean_task"] = ["task_type": 1, "items": [["param": ["mode": 999]]]]
        XCTAssertNil(try summary(item).modeName); XCTAssertTrue(try summary(item).roomNames.isEmpty)
        item["clean_task"] = ["items": [["zone": ["zone_id": 1, "zone_type": 1], "param": ["mode": 2]], ["zone": ["zone_id": 99, "zone_type": 1]]]]
        XCTAssertNil(try summary(item).modeName); XCTAssertTrue(try summary(item).roomNames.isEmpty)
    }

    func testSavedRouteUsesFrozenMapAndExplicitTypesWithoutFakeLiveRevisionsOrPoseTime() throws {
        let run = try NarwalHistoryCodec.detail(envelope(detailItem()), record: summary(), device: robot)
        XCTAssertTrue(run.isCloudRecord); XCTAssertEqual(run.cloudRecordID, "9007199254740993")
        XCTAssertEqual(run.startedAt, Date(timeIntervalSince1970: Double(start)))
        XCTAssertEqual(run.updatedAt, Date(timeIntervalSince1970: Double(start + 1800)))
        XCTAssertEqual(run.floorplan.pixels, Array(repeating: 0x101, count: 100))
        XCTAssertEqual(run.trajectory.segments.map(\.typeCode), [0, 1, 4])
        XCTAssertEqual(run.trajectory.points.first, RobotPathPoint(x: 0.5, y: 0.5))
        XCTAssertNil(run.trajectory.pose); XCTAssertNil(run.trajectory.sequenceID)
        XCTAssertNil(run.trajectory.deviceTimestampMilliseconds); XCTAssertNil(run.trajectory.editVersion)
        XCTAssertEqual(run.trajectory.mapVersion, 9); XCTAssertNil(run.floorplan.mapRevision)
        XCTAssertNotNil(run.importedAt); XCTAssertEqual(run.partialReason, CleaningHistoryStore.cloudSavedReason)
        let json = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
        for privateKey in ["user_uuid", "map_path", "untrusted.invalid", "not retained"] { XCTAssertFalse(json.contains(privateKey)) }
    }

    func testMissingTypedStatesDoNotInferCleaningFromArchiveStartIndices() throws {
        var detail = detailItem(); detail.removeValue(forKey: "trajectory_infos"); detail.removeValue(forKey: "map_version")
        let run = try NarwalHistoryCodec.detail(envelope(detail), record: summary(), device: robot)
        XCTAssertEqual(run.trajectory.segments.map(\.typeCode), [0]); XCTAssertNil(run.trajectory.mapVersion)
        XCTAssertNil(run.trajectory.editVersion); XCTAssertNil(run.floorplan.mapRevision)
    }

    func testWrongDetailIdentityInvalidGeometryAndUnsupportedFormatsReject() throws {
        let record = try summary()
        let modifications: [[String: Any]] = [
            ["record_id": recordID + 1], ["device_id": String(repeating: "b", count: 32)], ["map_id": 2],
            ["start_time": start + 1], ["end_time": start - 1], ["width": 4097], ["height": 0],
            ["map_data": "notbase64"], ["map_data": "AAAA"], ["map_data_format": 2],
            ["robot_trajectory_format": 3], ["robot_trajectory": "AA=="], ["rotate_angle": 90],
            ["trajectory_infos": [["trajectory_type": 4, "index": 99]]], ["trajectory_arcs": [["unknown": 1]]]
        ]
        for changes in modifications {
            let detail = detailItem().merging(changes) { _, new in new }
            XCTAssertThrowsError(try NarwalHistoryCodec.detail(envelope(detail), record: record, device: robot))
        }
    }

    func testHistoricalCloudImportDeduplicatesAndRetainsByDownloadDate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FreoCloudHistoryTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CleaningHistoryStore(directory: directory)
        let run = try NarwalHistoryCodec.detail(envelope(detailItem()), record: summary(), device: robot)
        let first = try await store.importCloud(run: run), second = try await store.importCloud(run: run)
        XCTAssertEqual(first.count, 1); XCTAssertEqual(second.count, 1); XCTAssertEqual(first[0].id, second[0].id)
        XCTAssertLessThan(run.updatedAt, Date().addingTimeInterval(-30 * 86_400))
        let loaded = try await CleaningHistoryStore(directory: directory).load()
        XCTAssertEqual(loaded, second)
        let other = RobotDevice(id: String(repeating: "b", count: 32), productKey: robot.productKey, name: "Other")
        let otherRun = try NarwalHistoryCodec.detail(envelope(detailItem(device: other)), record: summary(listItem(device: other), device: other), device: other)
        XCTAssertNotEqual(run.id, otherRun.id)
        let both = try await store.importCloud(run: otherRun)
        XCTAssertEqual(both.count, 2)
    }

    func testBackwardCompatibleObservedRecordAndCloudSourceValidation() async throws {
        let snapshot = RouteFixture.snapshot(), trajectory = try NarwalCodec.trajectory(snapshot: snapshot)
        let observed = CleaningRun(id: UUID(), startedAt: snapshot.capturedAt, updatedAt: snapshot.capturedAt,
            floorplan: snapshot.floorplan, trajectory: trajectory, partialReason: CleaningHistoryStore.partialCaptureReason)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observed)) as! [String: Any]
        json.removeValue(forKey: "cloudRecordID"); json.removeValue(forKey: "importedAt")
        let decoded = try JSONDecoder().decode(CleaningRun.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.isCloudRecord); XCTAssertNil(decoded.importedAt)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await CleaningHistoryStore(directory: directory).importCloud(run: decoded); XCTFail("Observed data cannot be presented as a Narwal saved record") } catch { }
    }

    func testAnExplicitOlderDownloadSurvivesCountRetention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CleaningHistoryStore(directory: directory, maximumRecords: 1)
        let recent = RouteFixture.snapshot(at: Date().addingTimeInterval(-10))
        _ = try await store.observe(snapshot: recent, trajectory: NarwalCodec.trajectory(snapshot: recent), windowID: UUID())
        let old = try NarwalHistoryCodec.detail(envelope(detailItem()), record: summary(), device: robot)
        let kept = try await store.importCloud(run: old)
        XCTAssertEqual(kept.count, 1); XCTAssertEqual(kept.first?.id, old.id)
    }
}
